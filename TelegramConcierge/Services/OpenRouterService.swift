import Foundation

actor OpenRouterService {
    private let baseURL = "https://openrouter.ai/api/v1/chat/completions"
    private let defaultModel = "google/gemini-3-flash-preview"
    private var apiKey: String = ""
    
    /// Returns the user-configured model or falls back to default
    private var model: String {
        KeychainHelper.load(key: KeychainHelper.openRouterModelKey) ?? defaultModel
    }
    
    /// Returns the user-configured provider order, or nil if not set
    private var providers: [String]? {
        guard let providersString = KeychainHelper.load(key: KeychainHelper.openRouterProvidersKey),
              !providersString.isEmpty else {
            return nil
        }
        // Parse comma-separated list, trim whitespace
        return providersString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    
    /// Returns the user-configured reasoning effort, defaulting to "high" for Gemini models
    private var reasoningEffort: String? {
        guard let effort = KeychainHelper.load(key: KeychainHelper.openRouterReasoningEffortKey),
              !effort.isEmpty else {
            return "high"
        }
        return effort
    }
    
    func configure(apiKey: String) {
        self.apiKey = apiKey
    }
    
    // MARK: - Token Management
    
    /// Dynamic context window limits based on user-configured chunk size
    private var configuredChunkSize: Int {
        if let saved = KeychainHelper.load(key: KeychainHelper.archiveChunkSizeKey),
           let value = Int(saved), value >= 5000 {
            return value
        }
        return 10000 // Default chunk size
    }
    
    private var minContextTokens: Int { configuredChunkSize }
    private var maxContextTokens: Int { configuredChunkSize * 2 }
    private var archiveThreshold: Int { configuredChunkSize * 2 }
    
    /// Result of context window processing
    struct ContextWindowResult {
        let messagesToSend: [Message]      // Messages that fit within budget
        let messagesToArchive: [Message]   // Messages that exceeded threshold and need archiving
        let currentTokenCount: Int         // Tokens in messagesToSend
        let needsArchiving: Bool           // True if we're at threshold and need to emit a chunk
    }
    
    /// Rough token estimation: ~4 characters per token, plus multimodal content
    /// Check if a filename is a video (videos are not sent to Gemini, so they cost 0 tokens)
    private func isVideoFile(_ fileName: String) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return ["mp4", "mov", "avi", "mkv", "webm", "m4v", "wmv", "flv", "3gp"].contains(ext)
    }
    
    /// Check if a filename is an audio file (excluding voice messages which are transcribed locally)
    private func isAudioFile(_ fileName: String) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        // Exclude .ogg and .oga - these are voice messages which are transcribed locally
        return ["mp3", "m4a", "wav", "flac", "aac", "opus", "wma", "aiff"].contains(ext)
    }
    
    /// Check if a filename is a voice message (transcribed locally, so 0 tokens for Gemini)
    private func isVoiceMessage(_ fileName: String) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return ["ogg", "oga"].contains(ext)
    }
    
    /// Estimate token cost for a document file
    /// Since documents are only sent inline for the CURRENT message (one agentic loop),
    /// historical messages just have a filename hint + description. We return minimal tokens.
    /// - Voice messages (.ogg/.oga): 0 tokens (transcribed locally)
    /// - All other files: 50 tokens (filename hint + description in history)
    private func estimateDocumentTokens(fileName: String, fileSize: Int) -> Int {
        // Voice messages are transcribed locally - 0 tokens for Gemini
        if isVoiceMessage(fileName) {
            return 0
        }
        
        // All documents: just filename hint + description
        return 50
    }
    
    /// Estimate token cost for an image
    /// Since images are only sent inline for the CURRENT message,
    /// historical messages just have a filename hint + description.
    private func estimateImageTokens(fileSize: Int) -> Int {
        return 50  // Filename hint + description
    }
    
    func estimateTokens(for message: Message) -> Int {
        var tokens = message.content.count / 4
        
        // Image token cost: 50 tokens (filename + description hint)
        for _ in message.imageFileNames {
            tokens += 50
        }
        
        // Document token cost: 50 tokens (filename + description hint)
        for fileName in message.documentFileNames {
            if isVoiceMessage(fileName) {
                tokens += 0  // Voice messages transcribed locally
            } else {
                tokens += 50
            }
        }
        
        // Include referenced attachments (from replied-to messages)
        for (index, _) in message.referencedImageFileNames.enumerated() {
            if index < message.referencedImageFileSizes.count {
                tokens += estimateImageTokens(fileSize: message.referencedImageFileSizes[index])
            } else {
                tokens += 250
            }
        }
        
        for (index, fileName) in message.referencedDocumentFileNames.enumerated() {
            if index < message.referencedDocumentFileSizes.count {
                tokens += estimateDocumentTokens(fileName: fileName, fileSize: message.referencedDocumentFileSizes[index])
            } else {
                if isVideoFile(fileName) || isVoiceMessage(fileName) {
                    tokens += 0
                } else if isAudioFile(fileName) {
                    tokens += 200
                } else {
                    tokens += 500
                }
            }
        }
        
        return max(tokens, 1)
    }
    
    /// Process messages with dynamic context window (25k-50k)
    /// When total exceeds 50k, returns oldest 25k for archival and keeps recent 25k
    func processContextWindow(_ messages: [Message]) -> ContextWindowResult {
        var totalTokens = 0
        for msg in messages {
            totalTokens += estimateTokens(for: msg)
        }
        
        // If under threshold, send all
        if totalTokens <= maxContextTokens {
            print("[OpenRouterService] Context window: \(messages.count) messages (~\(totalTokens) tokens)")
            return ContextWindowResult(
                messagesToSend: messages,
                messagesToArchive: [],
                currentTokenCount: totalTokens,
                needsArchiving: false
            )
        }
        
        // Exceeded threshold - need to archive oldest 25k and keep recent
        print("[OpenRouterService] Context exceeded \(maxContextTokens) tokens, triggering archival")
        
        // Find split point: archive oldest ~25k, keep rest
        var archiveTokens = 0
        var splitIndex = 0
        
        for (index, msg) in messages.enumerated() {
            let msgTokens = estimateTokens(for: msg)
            if archiveTokens + msgTokens > minContextTokens {
                splitIndex = index
                break
            }
            archiveTokens += msgTokens
        }
        
        // Ensure we archive at least something
        if splitIndex == 0 && !messages.isEmpty {
            splitIndex = 1
        }
        
        let toArchive = Array(messages.prefix(splitIndex))
        let toKeep = Array(messages.suffix(from: splitIndex))
        
        let keepTokens = toKeep.reduce(0) { $0 + estimateTokens(for: $1) }
        
        print("[OpenRouterService] Archiving \(toArchive.count) messages (~\(archiveTokens) tokens), keeping \(toKeep.count) messages (~\(keepTokens) tokens)")
        
        return ContextWindowResult(
            messagesToSend: toKeep,
            messagesToArchive: toArchive,
            currentTokenCount: keepTokens,
            needsArchiving: true
        )
    }
    
    /// Returns the most recent messages that fit within the token budget (legacy compatibility)
    private func truncateMessagesToTokenLimit(_ messages: [Message], maxTokens: Int) -> [Message] {
        var totalTokens = 0
        var includedMessages: [Message] = []
        
        // Iterate from most recent to oldest
        for message in messages.reversed() {
            let messageTokens = estimateTokens(for: message)
            if totalTokens + messageTokens > maxTokens {
                break
            }
            totalTokens += messageTokens
            includedMessages.insert(message, at: 0) // Maintain chronological order
        }
        
        print("[OpenRouterService] Context window: \(includedMessages.count)/\(messages.count) messages (~\(totalTokens) tokens)")
        return includedMessages
    }
    
    // MARK: - Chunk Summary Formatting
    
    /// Formats chunk summaries for system prompt injection
    private func formatChunkSummaries(_ chunks: [ConversationChunk], totalChunkCount: Int) -> String {
        guard !chunks.isEmpty else { return "" }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"
        
        let hiddenCount = totalChunkCount - chunks.count
        
        var output: String
        if hiddenCount > 0 {
            output = """
            
            
            ## ARCHIVED CONVERSATION HISTORY
            
            Showing \(chunks.count) recent chunks. **\(hiddenCount) older chunk(s) not shown.**
            - To view a chunk's full messages: `view_conversation_chunk(chunk_id: "ID")`
            - To see ALL \(totalChunkCount) chunks: `view_conversation_chunk()` with no arguments
            
            | # | ID | Size | Date Range | Summary |
            |---|-----|------|------------|---------|
            """
        } else {
            output = """
            
            
            ## ARCHIVED CONVERSATION HISTORY
            
            All \(chunks.count) archived chunk(s) shown below.
            - To view a chunk's full messages: `view_conversation_chunk(chunk_id: "ID")`
            
            | # | ID | Size | Date Range | Summary |
            |---|-----|------|------------|---------|
            """
        }
        
        for (index, chunk) in chunks.enumerated() {
            let startStr = dateFormatter.string(from: chunk.startDate)
            let endStr = dateFormatter.string(from: chunk.endDate)
            let shortId = String(chunk.id.uuidString.prefix(8))
            let formattedSummary = chunk.summary.replacingOccurrences(of: "\n", with: " ")
            
            output += "\n| \(index + 1) | \(shortId) | \(chunk.sizeLabel) | \(startStr)-\(endStr) | \(formattedSummary) |"
        }
        
        return output
    }


    
    // MARK: - Main Generation with Tool Support
    
    /// Generate a response, optionally with tools enabled.
    /// Returns either text content or tool calls that need execution.
    func generateResponse(
        messages: [Message],
        imagesDirectory: URL,
        documentsDirectory: URL,
        tools: [ToolDefinition]? = nil,
        toolResultMessages: [ToolInteraction]? = nil,
        calendarContext: String? = nil,
        emailContext: String? = nil,
        chunkSummaries: [ConversationChunk]? = nil,
        totalChunkCount: Int = 0,
        currentUserMessageId: UUID? = nil
    ) async throws -> LLMResponse {
        guard !apiKey.isEmpty else {
            throw OpenRouterError.notConfigured
        }
        
        // Build API messages
        var apiMessages: [OpenRouterAPIMessage] = []
        
        // Add system message with date/time context and tool awareness
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' HH:mm:ss"
        let currentDateTime = dateFormatter.string(from: Date())
        let timezone = TimeZone.current.identifier
        
        // Load persona settings
        let assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey)
        let userName = KeychainHelper.load(key: KeychainHelper.userNameKey)
        let structuredUserContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey)
        let claudeCodeDocumentModeEnabled =
            (KeychainHelper.load(key: KeychainHelper.claudeCodeDisableLegacyDocumentGenerationToolsKey) ?? "false")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
        
        // Build persona intro
        var personaIntro: String
        if let structured = structuredUserContext, !structured.isEmpty {
            personaIntro = structured
        } else {
            // Build a basic intro from name fields
            let assistantPart = assistantName.map { "Your name is \($0)." } ?? ""
            let userPart = userName.map { "You are assisting \($0)." } ?? ""
            personaIntro = [assistantPart, userPart].filter { !$0.isEmpty }.joined(separator: " ")
            if personaIntro.isEmpty {
                personaIntro = "You are a helpful AI assistant."
            }
        }
        
        let systemPrompt: String
        if tools != nil && !tools!.isEmpty {
            var prompt = """
            \(personaIntro)
            
            The user communicates with you via Telegram. They may send text messages, voice messages (which are automatically transcribed before you receive them), images, and documents.
            
            **Current date and time**: \(currentDateTime) (\(timezone))
            ⚠️ This timestamp is essential—use it as your reference for ALL time-sensitive reasoning: scheduling calendar events, setting reminders, interpreting email dates, and any "today", "tomorrow", or relative-time logic.
            
            """
            
            // Inject calendar context if available
            if let calendar = calendarContext, !calendar.isEmpty {
                prompt += """
                
                \(calendar)
                
                """
            }
            
            // Inject email context if available
            if let email = emailContext, !email.isEmpty {
                prompt += """
                
                \(email)
                
                """
            }
            
            // Inject conversation history chunks if available
            if let chunks = chunkSummaries, !chunks.isEmpty {
                prompt += formatChunkSummaries(chunks, totalChunkCount: totalChunkCount)
            }
            
            
            prompt += """
            You have access to tools that can help you answer questions. Use them when appropriate, especially for:
            - Current events, news, or real-time data
            - Prices, stock quotes, weather, or availability
            - Specific facts you're uncertain about
            - Any topic where fresh information would improve your answer
            - **Self-orchestration via reminders**: Use set_reminder not just for user requests, but proactively when YOU decide a future action would be valuable. Examples: scheduling a follow-up check, breaking complex tasks into timed steps, verifying results later, or any "I should do X later" thought. When the reminder triggers, you regain full tool access.
            - **Calendar management**: Use the calendar tools to view, add, edit, or delete events on the user's schedule
            - **Learning about the user**: Use add_to_user_context to save facts you learn. Use remove_from_user_context when info becomes outdated. Use rewrite_user_context sparingly for major cleanup. This builds your persistent memory.
            
            For simple questions you can answer directly, respond without using tools.
            """

            if claudeCodeDocumentModeEnabled {
                prompt += """
                
                **Claude Code routing for deliverables**:
                - For requests that involve generating deliverables such as documents, spreadsheets, presentations, websites, or coding projects, prefer Claude project tools.
                - Use this flow when needed: list_projects/create_project -> browse_project/read_project_file/add_project_files -> run_claude_code -> send_project_result.
                - When sending websites/apps or other multi-file outputs, prefer send_project_result with package_as='zip_project' unless the user explicitly asked for individual files.
                - For project cleanup requests, use flag_projects_for_deletion to mark projects; never assume deletion is complete until the user confirms in Settings.
                - Do not claim files/code were created unless run_claude_code reports file_changes_detected or returns created_files/modified_files.
                """
            }

            prompt += """
            
            🕐 **Reminder: Current time is exactly \(currentDateTime) (\(timezone))**
            """
            systemPrompt = prompt
        } else {
            var prompt = """
            \(personaIntro)
            
            The user communicates with you via Telegram. They may send text messages, voice messages (which are automatically transcribed before you receive them), images, and documents.
            
            **Current date and time**: \(currentDateTime) (\(timezone))
            ⚠️ This timestamp is essential—use it as your reference for ALL time-sensitive reasoning: scheduling calendar events, setting reminders, interpreting email dates, and any "today", "tomorrow", or relative-time logic.
            """
            
            // Inject calendar context if available
            if let calendar = calendarContext, !calendar.isEmpty {
                prompt += """
                
                
                \(calendar)
                """
            }
            
            // Inject email context if available
            if let email = emailContext, !email.isEmpty {
                prompt += """
                
                
                \(email)
                """
            }
            
            // Inject conversation history chunks if available
            if let chunks = chunkSummaries, !chunks.isEmpty {
                prompt += formatChunkSummaries(chunks, totalChunkCount: totalChunkCount)
            }
            
            
            prompt += "\n\n🕐 **Reminder: Current time is exactly \(currentDateTime) (\(timezone))**"
            systemPrompt = prompt
        }
        
        apiMessages.append(OpenRouterAPIMessage(
            role: "system",
            content: .text(systemPrompt)
        ))
        
        // Truncate messages to fit within token budget
        let truncatedMessages = truncateMessagesToTokenLimit(messages, maxTokens: maxContextTokens)
        
        // Date formatters for timestamps
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        
        let dateHeaderFormatter = DateFormatter()
        dateHeaderFormatter.dateFormat = "EEEE, d MMMM yyyy"
        
        let calendar = Calendar.current
        var lastMessageDate: Date? = nil
        
        // Convert conversation messages
        for message in truncatedMessages {
            let role = message.role == .user ? "user" : "assistant"
            
            // Check if we need to add a date header (new day)
            var dateHeader = ""
            if let lastDate = lastMessageDate {
                if !calendar.isDate(lastDate, inSameDayAs: message.timestamp) {
                    // New day - add date header
                    dateHeader = "--- \(dateHeaderFormatter.string(from: message.timestamp)) ---\n"
                }
            } else {
                // First message - add date header
                dateHeader = "--- \(dateHeaderFormatter.string(from: message.timestamp)) ---\n"
            }
            lastMessageDate = message.timestamp
            
            // Format time for this message
            let timePrefix = "[\(timeFormatter.string(from: message.timestamp))] "
            
            // Check if message has multimodal content (images or documents, including referenced ones)
            let hasImages = !message.imageFileNames.isEmpty
            let hasDocuments = !message.documentFileNames.isEmpty
            let hasReferencedImages = !message.referencedImageFileNames.isEmpty
            let hasReferencedDocuments = !message.referencedDocumentFileNames.isEmpty
            let hasMultimodal = hasImages || hasDocuments || hasReferencedImages || hasReferencedDocuments
            
            // Only send media inline for the CURRENT user message (during the active agentic loop)
            // Historical messages get text-only hints pointing to the read_document tool
            let isCurrentMessage = (currentUserMessageId != nil && message.id == currentUserMessageId)
            
            if hasMultimodal && isCurrentMessage {
                // Current message: use multimodal content array with inline base64 data
                var contentParts: [ContentPart] = []
                
                // Add referenced images first (context from replied-to messages)
                for refImageFileName in message.referencedImageFileNames {
                    let imageURL = imagesDirectory.appendingPathComponent(refImageFileName)
                    if let imageData = try? Data(contentsOf: imageURL) {
                        let base64String = imageData.base64EncodedString()
                        let mimeType = refImageFileName.hasSuffix(".png") ? "image/png" : "image/jpeg"
                        let dataURL = "data:\(mimeType);base64,\(base64String)"
                        contentParts.append(.image(ImageURL(url: dataURL)))
                    }
                }
                
                // Add referenced documents (context from replied-to messages)
                for refDocFileName in message.referencedDocumentFileNames {
                    let documentURL = documentsDirectory.appendingPathComponent(refDocFileName)
                    if let documentData = try? Data(contentsOf: documentURL) {
                        let base64String = documentData.base64EncodedString()
                        let ext = documentURL.pathExtension.lowercased()
                        let mimeType: String
                        switch ext {
                        case "pdf": mimeType = "application/pdf"
                        case "txt": mimeType = "text/plain"
                        case "md": mimeType = "text/markdown"
                        case "json": mimeType = "application/json"
                        case "csv": mimeType = "text/csv"
                        default: mimeType = "application/octet-stream"
                        }
                        let dataURL = "data:\(mimeType);base64,\(base64String)"
                        contentParts.append(.image(ImageURL(url: dataURL)))
                    }
                }
                
                // Add primary images
                for imageFileName in message.imageFileNames {
                    let imageURL = imagesDirectory.appendingPathComponent(imageFileName)
                    if let imageData = try? Data(contentsOf: imageURL) {
                        let base64String = imageData.base64EncodedString()
                        let mimeType = imageFileName.hasSuffix(".png") ? "image/png" : "image/jpeg"
                        let dataURL = "data:\(mimeType);base64,\(base64String)"
                        contentParts.append(.image(ImageURL(url: dataURL)))
                    }
                }
                
                // Add primary documents (PDFs sent directly to Gemini)
                for documentFileName in message.documentFileNames {
                    let documentURL = documentsDirectory.appendingPathComponent(documentFileName)
                    if let documentData = try? Data(contentsOf: documentURL) {
                        let base64String = documentData.base64EncodedString()
                        let ext = documentURL.pathExtension.lowercased()
                        let mimeType: String
                        switch ext {
                        case "pdf": mimeType = "application/pdf"
                        case "txt": mimeType = "text/plain"
                        case "md": mimeType = "text/markdown"
                        case "json": mimeType = "application/json"
                        case "csv": mimeType = "text/csv"
                        default: mimeType = "application/octet-stream"
                        }
                        let dataURL = "data:\(mimeType);base64,\(base64String)"
                        contentParts.append(.image(ImageURL(url: dataURL)))
                    }
                }
                
                // Build text content with timestamp, date header, and filename hints
                var textContent = message.content
                
                // Add hints for referenced attachments
                if !message.referencedImageFileNames.isEmpty {
                    let refImageList = message.referencedImageFileNames.joined(separator: ", ")
                    textContent = "[Referenced image(s) from cited message: \(refImageList)] \(textContent)"
                }
                if !message.referencedDocumentFileNames.isEmpty {
                    let refDocList = message.referencedDocumentFileNames.joined(separator: ", ")
                    textContent = "[Referenced document(s) from cited message: \(refDocList)] \(textContent)"
                }
                
                // Add hints for primary attachments
                if !message.imageFileNames.isEmpty {
                    let imageList = message.imageFileNames.joined(separator: ", ")
                    textContent = "[Image file(s): \(imageList)] \(textContent)"
                }
                if !message.documentFileNames.isEmpty {
                    let docList = message.documentFileNames.joined(separator: ", ")
                    textContent = "[Document file(s): \(docList)] \(textContent)"
                }
                
                if textContent.isEmpty {
                    textContent = (hasDocuments || hasReferencedDocuments) ? "Please analyze this document." : "What's in this image?"
                }
                // Add date header (if new day) and time prefix
                textContent = dateHeader + timePrefix + textContent
                contentParts.append(.text(textContent))
                
                apiMessages.append(OpenRouterAPIMessage(role: role, content: .parts(contentParts)))
            } else if hasMultimodal {
                // Historical message with media: text-only with hints to use read_document tool
                var textContent = message.content
                
                // Add hints for referenced attachments (historical) with descriptions
                if !message.referencedImageFileNames.isEmpty {
                    var parts: [String] = []
                    for filename in message.referencedImageFileNames {
                        if let desc = await FileDescriptionService.shared.get(filename: filename) {
                            parts.append("\(filename) — \"\(desc)\"")
                        } else {
                            parts.append(filename)
                        }
                    }
                    textContent = "[Referenced image(s): \(parts.joined(separator: "; ")) — use read_document to view] \(textContent)"
                }
                if !message.referencedDocumentFileNames.isEmpty {
                    var parts: [String] = []
                    for filename in message.referencedDocumentFileNames {
                        if let desc = await FileDescriptionService.shared.get(filename: filename) {
                            parts.append("\(filename) — \"\(desc)\"")
                        } else {
                            parts.append(filename)
                        }
                    }
                    textContent = "[Referenced document(s): \(parts.joined(separator: "; ")) — use read_document to view] \(textContent)"
                }
                
                // Add hints for primary attachments (historical) with descriptions
                if !message.imageFileNames.isEmpty {
                    var parts: [String] = []
                    for filename in message.imageFileNames {
                        if let desc = await FileDescriptionService.shared.get(filename: filename) {
                            parts.append("\(filename) — \"\(desc)\"")
                        } else {
                            parts.append(filename)
                        }
                    }
                    textContent = "[Past image(s): \(parts.joined(separator: "; ")) — use read_document to view] \(textContent)"
                }
                if !message.documentFileNames.isEmpty {
                    var parts: [String] = []
                    for filename in message.documentFileNames {
                        if let desc = await FileDescriptionService.shared.get(filename: filename) {
                            parts.append("\(filename) — \"\(desc)\"")
                        } else {
                            parts.append(filename)
                        }
                    }
                    textContent = "[Past document(s): \(parts.joined(separator: "; ")) — use read_document to view] \(textContent)"
                }
                
                if textContent.isEmpty {
                    textContent = (hasDocuments || hasReferencedDocuments) ? "[User sent a document]" : "[User sent an image]"
                }
                // Add date header (if new day) and time prefix
                textContent = dateHeader + timePrefix + textContent
                apiMessages.append(OpenRouterAPIMessage(role: role, content: .text(textContent)))
            } else {
                // Standard text message (may include downloaded file hints for assistant messages)
                var textContent = message.content
                
                // Add hints for downloaded files (email attachments, etc.) on assistant messages
                if !message.downloadedDocumentFileNames.isEmpty {
                    var parts: [String] = []
                    for filename in message.downloadedDocumentFileNames {
                        if let desc = await FileDescriptionService.shared.get(filename: filename) {
                            parts.append("\(filename) — \"\(desc)\"")
                        } else {
                            parts.append(filename)
                        }
                    }
                    textContent = textContent + "\n[Downloaded from email: \(parts.joined(separator: "; ")) — use read_document to view again]"
                }
                
                // Add date header (if new day) and time prefix to text content
                textContent = dateHeader + timePrefix + textContent
                apiMessages.append(OpenRouterAPIMessage(role: role, content: .text(textContent)))
            }
        }
        
        // Add tool interactions if this is a follow-up call
        // IMPORTANT: Collect file attachments separately - OpenRouter doesn't support
        // multimodal content in tool role messages, so we inject files as a user message
        var pendingFileAttachments: [FileAttachment] = []
        
        if let interactions = toolResultMessages {
            for interaction in interactions {
                // Add assistant's tool call message
                apiMessages.append(OpenRouterAPIMessage(
                    role: "assistant",
                    content: nil,
                    toolCalls: interaction.assistantToolCalls
                ))
                
                // Add tool results (text only - files will be added separately)
                for result in interaction.results {
                    // Collect file attachments for later injection
                    if !result.fileAttachments.isEmpty {
                        print("[OpenRouterService] Collecting \(result.fileAttachments.count) file attachment(s) from tool result for user-role injection")
                        pendingFileAttachments.append(contentsOf: result.fileAttachments)
                    }
                    
                    // Tool result is always text-only
                    apiMessages.append(OpenRouterAPIMessage(
                        role: "tool",
                        content: .text(result.content),
                        toolCallId: result.toolCallId
                    ))
                }
            }
            
            // After all tool results, inject collected file attachments as a user message
            // This is the OpenRouter-compatible way to make files visible to the model
            if !pendingFileAttachments.isEmpty {
                print("[OpenRouterService] Injecting \(pendingFileAttachments.count) file attachment(s) as user-role multimodal message")
                var contentParts: [ContentPart] = []
                
                // Build descriptive text about the files
                var fileDescriptions: [String] = []
                for attachment in pendingFileAttachments {
                    let base64String = attachment.data.base64EncodedString()
                    let dataURL = "data:\(attachment.mimeType);base64,\(base64String)"
                    print("[OpenRouterService] Adding file to user message: \(attachment.filename) (\(attachment.mimeType), \(attachment.data.count) bytes)")
                    contentParts.append(.image(ImageURL(url: dataURL)))
                    fileDescriptions.append(attachment.filename)
                }
                
                // Add text explaining what these files are
                let filesText = "[The tool downloaded the following file(s) which are now visible to you: \(fileDescriptions.joined(separator: ", ")). Analyze the content above to answer the user's question.]"
                contentParts.append(.text(filesText))
                
                apiMessages.append(OpenRouterAPIMessage(
                    role: "user",
                    content: .parts(contentParts)
                ))
            }
        }
        
        // Build request
        var providerPrefs: ProviderPreferences? = nil
        if let providerOrder = providers, !providerOrder.isEmpty {
            providerPrefs = ProviderPreferences(order: providerOrder)
        }
        
        var reasoningConfig: ReasoningConfig? = nil
        if let effort = reasoningEffort {
            reasoningConfig = ReasoningConfig(effort: effort)
        }
        
        let body = OpenRouterRequest(
            model: model,
            messages: apiMessages,
            tools: tools,
            provider: providerPrefs,
            reasoning: reasoningConfig
        )
        
        let url = URL(string: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("TelegramConcierge/1.0", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Telegram Concierge Bot", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 120 // Longer timeout for tool reasoning
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            // Log the raw error response for debugging
            let rawResponse = String(data: data, encoding: .utf8) ?? "Unable to decode error response"
            print("[OpenRouterService] HTTP \(httpResponse.statusCode) error. Raw response: \(rawResponse)")
            
            if let errorResponse = try? JSONDecoder().decode(OpenRouterErrorResponse.self, from: data) {
                throw OpenRouterError.apiError(errorResponse.error.message)
            }
            throw OpenRouterError.httpError(httpResponse.statusCode)
        }
        
        let decoded: OpenRouterResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
        } catch {
            // Log the raw response for debugging
            let rawResponse = String(data: data, encoding: .utf8) ?? "Unable to decode response as string"
            print("[OpenRouterService] JSON decode failed. Raw response: \(rawResponse.prefix(1000))")
            print("[OpenRouterService] Decode error: \(error)")
            throw error
        }
        
        guard let choice = decoded.choices.first else {
            throw OpenRouterError.noContent
        }
        
        // Extract usage info for token tracking
        let promptTokens = decoded.usage?.promptTokens
        let completionTokens = decoded.usage?.completionTokens
        if let pt = promptTokens, let ct = completionTokens {
            print("[OpenRouterService] Usage: \(pt) prompt tokens, \(ct) completion tokens")
        }
        
        // Check if the model wants to call tools
        if let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty {
            return .toolCalls(
                assistantMessage: AssistantToolCallMessage(
                    content: choice.message.content,
                    toolCalls: toolCalls
                ),
                calls: toolCalls,
                promptTokens: promptTokens
            )
        }
        
        // Regular text response
        guard let content = choice.message.content else {
            throw OpenRouterError.noContent
        }
        
        return .text(content, promptTokens: promptTokens)
    }
    
    // MARK: - File Description Generation
    
    /// Generate brief descriptions for files while context is still available
    /// Returns a dictionary mapping filename to description
    func generateFileDescriptions(
        files: [(filename: String, data: Data, mimeType: String)],
        conversationContext: [Message] = []
    ) async throws -> [String: String] {
        guard !apiKey.isEmpty else {
            throw OpenRouterError.notConfigured
        }
        
        guard !files.isEmpty else {
            return [:]
        }
        
        print("[OpenRouterService] Generating descriptions for \(files.count) file(s) with \(conversationContext.count) context messages")
        
        // Build conversation context as API messages (text only, recent messages)
        var apiMessages: [OpenRouterAPIMessage] = []
        
        // System message with context awareness
        let systemPrompt = """
        You are a helpful assistant that provides brief, accurate file descriptions.
        
        You have access to the recent conversation context. Use this to provide more meaningful descriptions \
        that reference relevant context. For example, if the user mentioned "the quarterly report" earlier, \
        and they send a PDF, your description should reference that context.
        """
        apiMessages.append(OpenRouterAPIMessage(role: "system", content: .text(systemPrompt)))
        
        // Add recent conversation messages (last 10 for context, text only to save tokens)
        let recentMessages = conversationContext.suffix(10)
        for message in recentMessages {
            let role = message.role == .user ? "user" : "assistant"
            var text = message.content
            
            // Add hints about attached files for context
            if !message.imageFileNames.isEmpty {
                text = "[Attached image(s): \(message.imageFileNames.joined(separator: ", "))] \(text)"
            }
            if !message.documentFileNames.isEmpty {
                text = "[Attached document(s): \(message.documentFileNames.joined(separator: ", "))] \(text)"
            }
            
            apiMessages.append(OpenRouterAPIMessage(role: role, content: .text(text)))
        }
        
        // Build multimodal content with all files
        var contentParts: [ContentPart] = []
        
        for file in files {
            let base64String = file.data.base64EncodedString()
            let dataURL = "data:\(file.mimeType);base64,\(base64String)"
            
            // OpenRouter expects all files as ImageURL
            contentParts.append(.image(ImageURL(url: dataURL)))
        }
        
        // Build the prompt listing all filenames
        let fileList = files.map { $0.filename }.joined(separator: ", ")
        let prompt = """
        The user just sent these file(s). Based on the conversation context above, provide a brief description \
        (20-50 words) for each file that summarizes its content and relevance.
        
        This description will help you remember what the file contains in future conversations.
        
        Files: \(fileList)
        
        Format your response exactly like this (one per line):
        filename1.ext: Description of the first file.
        filename2.ext: Description of the second file.
        
        Be concise but include relevant context from the conversation if applicable.
        """
        contentParts.append(.text(prompt))
        
        // Add user message with files
        apiMessages.append(OpenRouterAPIMessage(role: "user", content: .parts(contentParts)))
        
        let request = OpenRouterRequest(
            model: model,
            messages: apiMessages,
            tools: nil,
            provider: providers.map { ProviderPreferences(order: $0) },
            reasoning: nil  // Keep it fast
        )
        
        // Make API call
        var urlRequest = URLRequest(url: URL(string: baseURL)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(OpenRouterErrorResponse.self, from: data) {
                throw OpenRouterError.apiError(errorResponse.error.message)
            }
            throw OpenRouterError.httpError(httpResponse.statusCode)
        }
        
        let apiResponse = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
        
        guard let content = apiResponse.choices.first?.message.content else {
            throw OpenRouterError.noContent
        }
        
        // Parse response into dictionary
        var descriptions: [String: String] = [:]
        let lines = content.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            
            // Find first colon that separates filename from description
            if let colonIndex = trimmed.firstIndex(of: ":") {
                let filename = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let description = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                
                // Match to our actual filenames (case-insensitive, handle potential variations)
                if let matchedFile = files.first(where: { 
                    $0.filename.lowercased() == filename.lowercased() ||
                    filename.lowercased().contains($0.filename.lowercased()) ||
                    $0.filename.lowercased().contains(filename.lowercased())
                }) {
                    descriptions[matchedFile.filename] = description
                }
            }
        }
        
        print("[OpenRouterService] Generated \(descriptions.count) description(s)")
        return descriptions
    }
}

// MARK: - Tool Interaction (for follow-up calls)

struct ToolInteraction {
    let assistantToolCalls: [ToolCall]
    let results: [ToolResultMessage]
}

// MARK: - Request Models

struct ProviderPreferences: Codable {
    let order: [String]
}

struct ReasoningConfig: Codable {
    let effort: String
}

struct OpenRouterRequest: Codable {
    let model: String
    let messages: [OpenRouterAPIMessage]
    let tools: [ToolDefinition]?
    let provider: ProviderPreferences?
    let reasoning: ReasoningConfig?
}

struct OpenRouterAPIMessage: Codable {
    let role: String
    let content: MessageContent?
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    
    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
    
    init(role: String, content: MessageContent?, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

// Supports both plain string and multimodal array content
enum MessageContent: Codable {
    case text(String)
    case parts([ContentPart])
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
            try container.encode(string)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else if let parts = try? container.decode([ContentPart].self) {
            self = .parts(parts)
        } else {
            throw DecodingError.typeMismatch(MessageContent.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected String or [ContentPart]"))
        }
    }
}

enum ContentPart: Codable {
    case text(String)
    case image(ImageURL)
    case file(FileURL)
    
    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
        case fileUrl = "file_url"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let imageUrl):
            try container.encode("image_url", forKey: .type)
            try container.encode(imageUrl, forKey: .imageUrl)
        case .file(let fileUrl):
            // OpenRouter expects ALL files (including PDFs) to use image_url type
            // The MIME type in the data URL tells OpenRouter what kind of content it is
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: fileUrl.url), forKey: .imageUrl)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image_url":
            let imageUrl = try container.decode(ImageURL.self, forKey: .imageUrl)
            self = .image(imageUrl)
        case "file_url":
            let fileUrl = try container.decode(FileURL.self, forKey: .fileUrl)
            self = .file(fileUrl)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content type")
        }
    }
}

struct ImageURL: Codable {
    let url: String
}

struct FileURL: Codable {
    let url: String
}

// MARK: - Response Models

struct OpenRouterResponse: Codable {
    let choices: [OpenRouterChoice]
    let usage: OpenRouterUsage?
}

struct OpenRouterUsage: Codable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

struct OpenRouterChoice: Codable {
    let message: OpenRouterResponseMessage
}

struct OpenRouterResponseMessage: Codable {
    let role: String
    let content: String?
    let toolCalls: [ToolCall]?
    
    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
    }
}

struct OpenRouterErrorResponse: Codable {
    let error: OpenRouterErrorDetail
}

struct OpenRouterErrorDetail: Codable {
    let message: String
    let type: String?
    let code: String?
}

// MARK: - Errors

enum OpenRouterError: LocalizedError {
    case notConfigured
    case invalidResponse
    case httpError(Int)
    case apiError(String)
    case noContent
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OpenRouter API key is not configured"
        case .invalidResponse:
            return "Invalid response from OpenRouter"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .apiError(let message):
            return "API error: \(message)"
        case .noContent:
            return "No content in response"
        }
    }
}
