import Foundation

// MARK: - Conversation Archive Service

/// Manages conversation chunking, summarization, and search
actor ConversationArchiveService {
    
    // MARK: - Configuration
    
    /// Dynamic chunk size based on user setting
    private var configuredChunkSize: Int {
        if let saved = KeychainHelper.load(key: KeychainHelper.archiveChunkSizeKey),
           let value = Int(saved), value >= 5000 {
            return value
        }
        return 10000 // Default chunk size
    }
    
    private var minContextTokens: Int { configuredChunkSize }
    private var maxContextTokens: Int { configuredChunkSize * 2 }
    private var temporaryChunkSize: Int { configuredChunkSize }
    private var consolidatedChunkSize: Int { configuredChunkSize * 4 }
    private let summaryTargetTokens = 1500
    private let chunksToConsolidate = 4      // 4 × chunk_size = consolidatedChunkSize
    private let consolidationTriggerCount = 6 // Trigger at 6 temps, leaving 2 as buffer
    
    // OpenRouter config for summarization/search
    // Using Gemini for summarization since it can understand multimodal context
    private let model = "google/gemini-3-flash-preview"
    private let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private var apiKey: String = ""
    
    // MARK: - Summarization Context
    
    /// Context provided to the LLM during summarization for better understanding
    struct SummarizationContext {
        let personaContext: String?           // User's structured context (who they are)
        let assistantName: String?            // Assistant's name
        let userName: String?                 // User's name
        let previousSummaries: [String]       // Summaries of earlier chunks (chronological)
        let currentConversationContext: String? // Recent conversation messages (what's happening now)
        
        static let empty = SummarizationContext(
            personaContext: nil,
            assistantName: nil,
            userName: nil,
            previousSummaries: [],
            currentConversationContext: nil
        )
    }
    
    // MARK: - Storage
    
    private let appFolder: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    
    private var archiveFolder: URL {
        let dir = appFolder.appendingPathComponent("archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private var indexFileURL: URL {
        archiveFolder.appendingPathComponent("chunk_index.json")
    }
    
    private var pendingIndexFileURL: URL {
        archiveFolder.appendingPathComponent("pending_chunks.json")
    }
    
    private var chunkIndex: ChunkIndex = .empty()
    private var pendingIndex: PendingChunkIndex = .empty()
    
    // Cached live context for consolidation (updated when archiveMessages is called)
    private var cachedLiveContext: String?
    
    // MARK: - Initialization
    
    init() {
        loadIndex()
        loadPendingIndex()
    }
    
    /// Called on startup to resume any pending chunks from previous crash
    func recoverPendingChunks() async {
        guard !pendingIndex.pendingChunks.isEmpty else { return }
        
        print("[ArchiveService] Found \(pendingIndex.pendingChunks.count) pending chunk(s) from previous session, recovering...")
        
        for pending in pendingIndex.pendingChunks {
            do {
                // Load the raw messages
                let fileURL = archiveFolder.appendingPathComponent(pending.rawContentFileName)
                let data = try Data(contentsOf: fileURL)
                let messages = try JSONDecoder().decode([Message].self, from: data)
                
                // Generate summary (with infinite retry)
                var summary: String? = nil
                var retryCount = 0
                while summary == nil {
                    do {
                        summary = try await generateSummary(for: messages, startDate: pending.startDate, endDate: pending.endDate, context: .empty)
                    } catch {
                        retryCount += 1
                        let delay = min(2.0 * pow(2.0, Double(min(retryCount - 1, 5))), 60.0)
                        print("[ArchiveService] Recovery summary failed (attempt \(retryCount)): \(error). Retrying in \(Int(delay))s...")
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
                
                // Create the completed chunk
                let chunk = ConversationChunk(
                    id: pending.id,
                    type: .temporary,
                    startDate: pending.startDate,
                    endDate: pending.endDate,
                    tokenCount: pending.tokenCount,
                    messageCount: pending.messageCount,
                    summary: summary!,
                    rawContentFileName: pending.rawContentFileName
                )
                
                chunkIndex.chunks.append(chunk)
                print("[ArchiveService] Recovered pending chunk \(pending.id.uuidString.prefix(8))...")
            } catch {
                print("[ArchiveService] Failed to recover pending chunk \(pending.id): \(error)")
            }
        }
        
        // Clear pending and save
        pendingIndex.pendingChunks.removeAll()
        savePendingIndex()
        saveIndex()
        
        // Check if consolidation is needed
        await checkAndConsolidate()
    }
    
    func configure(apiKey: String) {
        self.apiKey = apiKey
    }
    
    /// Reload chunk index and pending index from disk
    /// Call this after Mind restore to pick up the restored data
    func reloadFromDisk() {
        loadIndex()
        loadPendingIndex()
        print("[ArchiveService] Reloaded index from disk (\(chunkIndex.chunks.count) chunks)")
    }
    
    /// Clear all archived chunks and indices (for memory reset)
    func clearAllArchives() {
        // Delete all chunk files
        for chunk in chunkIndex.chunks {
            let fileURL = archiveFolder.appendingPathComponent(chunk.rawContentFileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        // Delete pending chunk files
        for pending in pendingIndex.pendingChunks {
            let fileURL = archiveFolder.appendingPathComponent(pending.rawContentFileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        // Reset indices
        chunkIndex = .empty()
        pendingIndex = .empty()
        cachedLiveContext = nil
        
        // Save empty indices
        saveIndex()
        savePendingIndex()
        
        print("[ArchiveService] Cleared all archives")
    }
    
    // MARK: - Public Interface
    
    /// Get the current context token limits
    var contextLimits: (min: Int, max: Int) {
        (minContextTokens, maxContextTokens)
    }
    
    /// Archive a batch of messages as a temporary chunk
    /// Uses pending chunk pattern: save raw data first, then summarize, for crash safety
    func archiveMessages(_ messages: [Message], context: SummarizationContext = .empty) async throws -> ConversationChunk {
        guard !messages.isEmpty else {
            throw ArchiveError.emptyMessages
        }
        
        let chunkId = UUID()
        let startDate = messages.first!.timestamp
        let endDate = messages.last!.timestamp
        let tokenCount = messages.reduce(0) { $0 + estimateTokens(for: $1) }
        
        // Cache live context for potential consolidation
        cachedLiveContext = context.currentConversationContext
        
        // Save raw messages to file FIRST (crash safety)
        let fileName = "\(chunkId.uuidString).json"
        let fileURL = archiveFolder.appendingPathComponent(fileName)
        let data = try JSONEncoder().encode(messages)
        try data.write(to: fileURL)
        
        // Create pending chunk record (so we can recover if app crashes during summarization)
        let pending = PendingChunk(
            id: chunkId,
            startDate: startDate,
            endDate: endDate,
            tokenCount: tokenCount,
            messageCount: messages.count,
            rawContentFileName: fileName,
            createdAt: Date()
        )
        pendingIndex.pendingChunks.append(pending)
        savePendingIndex()
        
        // Generate summary with full context (caller handles retry)
        let summary = try await generateSummary(for: messages, startDate: startDate, endDate: endDate, context: context)
        
        let chunk = ConversationChunk(
            id: chunkId,
            type: .temporary,
            startDate: startDate,
            endDate: endDate,
            tokenCount: tokenCount,
            messageCount: messages.count,
            summary: summary,
            rawContentFileName: fileName
        )
        
        chunkIndex.chunks.append(chunk)
        
        // Remove from pending (summarization complete)
        pendingIndex.pendingChunks.removeAll { $0.id == chunkId }
        savePendingIndex()
        saveIndex()
        
        print("[ArchiveService] Created temporary chunk \(chunkId.uuidString.prefix(8))... (\(tokenCount) tokens, \(messages.count) messages)")
        
        // Check if we need to consolidate
        await checkAndConsolidate()
        
        return chunk
    }
    
    /// Get summaries of recent chunks for system prompt injection
    /// Returns: last 5 consolidated (100k) chunks + ALL temporary (25k) chunks, chronologically ordered
    func getRecentChunkSummaries(count: Int = 5) -> [ConversationChunk] {
        // Get last N consolidated chunks
        let consolidatedChunks = chunkIndex.chunks
            .filter { $0.type == .consolidated }
            .sorted { $0.startDate < $1.startDate }
            .suffix(count)
        
        // Get ALL temporary chunks (recent overflow not yet consolidated)
        let temporaryChunks = chunkIndex.temporaryChunks  // Already sorted by startDate
        
        // Combine and sort chronologically
        let combined = Array(consolidatedChunks) + temporaryChunks
        return combined.sorted { $0.startDate < $1.startDate }
    }
    
    /// Get all chunk summaries (for deep search)
    func getAllChunks() -> [ConversationChunk] {
        return chunkIndex.orderedChunks
    }
    
    /// Get the full content of a specific chunk (for direct viewing)
    func getChunkContent(chunkId: UUID) async throws -> String {
        print("[ArchiveService] getChunkContent called for ID: \(chunkId.uuidString)")
        
        guard let chunk = chunkIndex.chunks.first(where: { $0.id == chunkId }) else {
            print("[ArchiveService] Chunk not found in index. Total chunks: \(chunkIndex.chunks.count)")
            throw ArchiveError.chunkNotFound
        }
        
        print("[ArchiveService] Found chunk with fileName: \(chunk.rawContentFileName)")
        
        // Load raw messages
        let fileURL = archiveFolder.appendingPathComponent(chunk.rawContentFileName)
        print("[ArchiveService] Loading from: \(fileURL.path)")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[ArchiveService] ERROR: File does not exist at path: \(fileURL.path)")
            throw ArchiveError.fileNotFound(path: fileURL.path)
        }
        
        let data = try Data(contentsOf: fileURL)
        print("[ArchiveService] Loaded \(data.count) bytes")
        
        let messages = try JSONDecoder().decode([Message].self, from: data)
        print("[ArchiveService] Decoded \(messages.count) messages")
        
        // Return formatted conversation
        return await formatMessagesForSearch(messages)
    }
    
    /// Search a specific chunk for relevant information
    func searchChunk(chunkId: UUID, query: String) async throws -> [String] {
        guard let chunk = chunkIndex.chunks.first(where: { $0.id == chunkId }) else {
            throw ArchiveError.chunkNotFound
        }
        
        // Load raw messages
        let fileURL = archiveFolder.appendingPathComponent(chunk.rawContentFileName)
        let data = try Data(contentsOf: fileURL)
        let messages = try JSONDecoder().decode([Message].self, from: data)
        
        // Convert to text
        let conversationText = await formatMessagesForSearch(messages)
        
        // Extract relevant excerpts
        return try await extractExcerpts(from: conversationText, query: query)
    }
    
    /// Identify which chunks might contain relevant information (for older chunks)
    func identifyRelevantChunks(query: String, excludeRecent: Int = 5) async throws -> [ChunkIdentification] {
        let olderChunks = Array(chunkIndex.orderedChunks.dropLast(excludeRecent))
        guard !olderChunks.isEmpty else { return [] }
        
        // Build summary list for the LLM
        var summaryList = ""
        for (index, chunk) in olderChunks.enumerated() {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .short
            
            summaryList += """
            Chunk \(chunk.id.uuidString):
            - Date: \(dateFormatter.string(from: chunk.startDate)) to \(dateFormatter.string(from: chunk.endDate))
            - Summary: \(chunk.summary)
            
            """
        }
        
        let systemPrompt = """
        You are analyzing conversation history summaries to find which chunks might contain relevant information.
        
        OUTPUT STRICT JSON ONLY:
        { "relevant_chunks": [{"chunkId": "uuid", "relevance": "brief reason"}] }
        
        If no chunks are relevant, return: { "relevant_chunks": [] }
        """
        
        let userPrompt = """
        QUERY: \(query)
        
        AVAILABLE CHUNKS:
        \(summaryList)
        
        Which chunks might contain information relevant to the query?
        """
        
        let response = try await callOpenRouter(systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: 2000)
        
        guard let jsonData = extractFirstJSONObjectData(from: response),
              let result = try? JSONDecoder().decode(ChunkIdentificationResult.self, from: jsonData) else {
            return []
        }
        
        return result.relevantChunks
    }
    
    // MARK: - Consolidation
    
    private func checkAndConsolidate() async {
        let temps = chunkIndex.temporaryChunks
        
        if temps.count >= consolidationTriggerCount {
            let toConsolidate = Array(temps.prefix(chunksToConsolidate))
            
            do {
                try await consolidateChunks(toConsolidate)
            } catch {
                print("[ArchiveService] Consolidation failed: \(error)")
            }
        }
    }
    
    private func consolidateChunks(_ chunks: [ConversationChunk]) async throws {
        guard chunks.count == chunksToConsolidate else { return }
        
        let consolidatedId = UUID()
        let startDate = chunks.first!.startDate
        let endDate = chunks.last!.endDate
        
        // Load and merge all messages
        var allMessages: [Message] = []
        for chunk in chunks {
            let fileURL = archiveFolder.appendingPathComponent(chunk.rawContentFileName)
            let data = try Data(contentsOf: fileURL)
            let messages = try JSONDecoder().decode([Message].self, from: data)
            allMessages.append(contentsOf: messages)
        }
        
        let totalTokens = allMessages.reduce(0) { $0 + estimateTokens(for: $1) }
        
        // Save consolidated raw content
        let fileName = "\(consolidatedId.uuidString).json"
        let fileURL = archiveFolder.appendingPathComponent(fileName)
        let data = try JSONEncoder().encode(allMessages)
        try data.write(to: fileURL)
        
        // Build rich chronological context for consolidation
        // 1. Summaries of chunks BEFORE the ones being consolidated (for historical context)
        // 2. Summaries of chunks AFTER the ones being consolidated (for forward context)
        let consolidatingIds = Set(chunks.map { $0.id })
        let allOrderedChunks = chunkIndex.orderedChunks
        
        // Collect summaries chronologically before and after the consolidation period
        var summariesBefore: [String] = []
        var summariesAfter: [String] = []
        
        for chunk in allOrderedChunks {
            guard !consolidatingIds.contains(chunk.id) else { continue }
            
            if chunk.endDate < startDate {
                // This chunk is older than what we're consolidating
                summariesBefore.append("[\(chunk.sizeLabel) chunk, \(formatDateRange(chunk.startDate, chunk.endDate))]: \(chunk.summary)")
            } else if chunk.startDate > endDate {
                // This chunk is newer than what we're consolidating
                summariesAfter.append("[\(chunk.sizeLabel) chunk, \(formatDateRange(chunk.startDate, chunk.endDate))]: \(chunk.summary)")
            }
        }
        
        // Format the "after" context: newer chunks + current live conversation
        var afterParts: [String] = summariesAfter
        if let liveContext = cachedLiveContext, !liveContext.isEmpty {
            afterParts.append("[CURRENT LIVE CONVERSATION]:\n\(liveContext)")
        }
        let afterContext = afterParts.isEmpty ? nil : afterParts.joined(separator: "\n\n")
        
        let consolidationContext = SummarizationContext(
            personaContext: KeychainHelper.load(key: KeychainHelper.structuredUserContextKey),
            assistantName: KeychainHelper.load(key: KeychainHelper.assistantNameKey),
            userName: KeychainHelper.load(key: KeychainHelper.userNameKey),
            previousSummaries: summariesBefore,
            currentConversationContext: afterContext
        )
        let summary = try await generateSummary(for: allMessages, startDate: startDate, endDate: endDate, context: consolidationContext)
        
        let consolidatedChunk = ConversationChunk(
            id: consolidatedId,
            type: .consolidated,
            startDate: startDate,
            endDate: endDate,
            tokenCount: totalTokens,
            messageCount: allMessages.count,
            summary: summary,
            rawContentFileName: fileName
        )
        
        // Remove temporary chunks and their files
        for chunk in chunks {
            chunkIndex.chunks.removeAll { $0.id == chunk.id }
            let oldFileURL = archiveFolder.appendingPathComponent(chunk.rawContentFileName)
            try? FileManager.default.removeItem(at: oldFileURL)
        }
        
        // Add consolidated chunk
        chunkIndex.chunks.append(consolidatedChunk)
        saveIndex()
        
        print("[ArchiveService] Consolidated \(chunks.count) chunks into \(consolidatedId.uuidString.prefix(8))... (\(totalTokens) tokens)")
    }
    
    // MARK: - Summarization
    
    private func generateSummary(for messages: [Message], startDate: Date, endDate: Date, context: SummarizationContext) async throws -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        let conversationText = await formatMessagesForSummary(messages)
        
        // Build context sections for the prompt
        var contextSections: [String] = []
        
        // Persona/Identity context
        if let persona = context.personaContext, !persona.isEmpty {
            contextSections.append("USER PROFILE:\n\(persona)")
        } else {
            var identityParts: [String] = []
            if let assistantName = context.assistantName, !assistantName.isEmpty {
                identityParts.append("Assistant name: \(assistantName)")
            }
            if let userName = context.userName, !userName.isEmpty {
                identityParts.append("User name: \(userName)")
            }
            if !identityParts.isEmpty {
                contextSections.append("IDENTITY:\n\(identityParts.joined(separator: "\n"))")
            }
        }
        
        // Previous chunk summaries
        if !context.previousSummaries.isEmpty {
            let summariesText = context.previousSummaries.enumerated().map { idx, summary in
                "[Chunk \(idx + 1)] \(summary)"
            }.joined(separator: "\n\n")
            contextSections.append("PREVIOUS CONVERSATION SUMMARIES:\n\(summariesText)")
        }
        
        // Current conversation context (what's happening now, after the chunk)
        if let current = context.currentConversationContext, !current.isEmpty {
            contextSections.append("CURRENT CONVERSATION (most recent, for context only):\n\(current)")
        }
        
        let contextBlock = contextSections.isEmpty ? "" : """
        
        === CONTEXT (for understanding only, DO NOT include in summary) ===
        \(contextSections.joined(separator: "\n\n"))
        === END CONTEXT ===
        
        """
        
        let systemPrompt = """
        You are summarizing a specific segment of an ongoing conversation.\(contextBlock)
        YOUR TASK:
        Summarize ONLY the conversation segment below (make it a detailed ~1000 token summary, approximately 750 words).
        Use any context provided above to understand relationships, references, names, and meaning,
        but the summary should ONLY cover the messages in the segment being archived.
        
        Include:
        1. Key topics discussed in this segment
        2. Important decisions or information shared
        3. Any relevant action items or follow-ups mentioned
        
        OUTPUT STRICT JSON:
        { "summary": "...", "key_topics": ["topic1", "topic2", ...] }
        """
        
        let userPrompt = """
        CONVERSATION SEGMENT TO SUMMARIZE
        Period: \(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))
        
        \(conversationText.prefix(100000))
        """
        
        let response = try await callOpenRouter(systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: 2000)
        
        if let jsonData = extractFirstJSONObjectData(from: response),
           let result = try? JSONDecoder().decode(SummaryExtractionResult.self, from: jsonData) {
            let topics = result.keyTopics.joined(separator: ", ")
            return "\(result.summary) [Topics: \(topics)]"
        }
        
        // Fallback: use raw response
        return response.prefix(6000).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Excerpt Extraction
    
    private func extractExcerpts(from text: String, query: String) async throws -> [String] {
        let systemPrompt = """
        Extract the most relevant parts of the conversation that answer the query.
        Cite verbatim the relevant exchanges.
        
        OUTPUT STRICT JSON: { "excerpts": ["...", "..."] }
        """
        
        let userPrompt = """
        QUERY: \(query)
        
        CONVERSATION:
        \(text.prefix(100000))
        """
        
        let response = try await callOpenRouter(systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: 4000)
        
        if let jsonData = extractFirstJSONObjectData(from: response) {
            struct ExcerptResult: Codable { let excerpts: [String] }
            if let result = try? JSONDecoder().decode(ExcerptResult.self, from: jsonData) {
                return result.excerpts
            }
        }
        
        return []
    }
    
    // MARK: - OpenRouter API
    
    private func callOpenRouter(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        guard !apiKey.isEmpty else {
            throw ArchiveError.notConfigured
        }
        
        struct Request: Encodable {
            struct Message: Encodable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let max_tokens: Int
            let temperature: Double
        }
        
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        
        let body = Request(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            max_tokens: maxTokens,
            temperature: 0.3
        )
        
        var request = URLRequest(url: openRouterURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ArchiveError.apiError
        }
        
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }
    
    // MARK: - Helpers
    
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
    
    private func isImageFile(_ fileName: String) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"].contains(ext)
    }
    
    /// Check if a filename is a supported text-based document
    private func isTextDocument(_ fileName: String) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return ["pdf", "txt", "doc", "docx", "rtf", "md", "csv", "json", "xml", "html", "htm", "xls", "xlsx"].contains(ext)
    }
    
    private func estimateTokens(for message: Message) -> Int {
        var tokens = message.content.count / 4
        
        // Image token cost: 0.5 tokens per KB
        if let imageSize = message.imageFileSize {
            tokens += max(imageSize / 2048, 50)  // Min 50 tokens
        } else if message.imageFileName != nil {
            tokens += 250  // Fallback if size unknown
        }
        
        // Document token cost - varies by type
        if let docFileName = message.documentFileName {
            if isVideoFile(docFileName) {
                // Videos not sent to Gemini (requires YouTube upload)
                tokens += 50
            } else if isVoiceMessage(docFileName) {
                // Voice messages are transcribed locally - 0 tokens
                tokens += 0
            } else if isAudioFile(docFileName) {
                // Audio: 32 tokens/sec, assuming 128kbps = 16KB/sec
                // tokens = fileSize / 512
                if let docSize = message.documentFileSize {
                    tokens += max(docSize / 512, 50)
                } else {
                    tokens += 200  // ~3 seconds fallback
                }
            } else if isImageFile(docFileName) {
                // Images sent as documents: 0.5 tokens per KB
                if let docSize = message.documentFileSize {
                    tokens += max(docSize / 2048, 50)
                } else {
                    tokens += 250
                }
            } else if isTextDocument(docFileName) {
                // PDFs and text documents: 0.2 tokens per byte, capped at 3000
                if let docSize = message.documentFileSize {
                    tokens += min(docSize / 5, 3000)
                } else {
                    tokens += 500
                }
            } else {
                // Unsupported file types (zip, exe, etc.) - not processed by Gemini
                tokens += 50
            }
        }
        
        return max(tokens, 1)
    }
    
    private func formatMessagesForSummary(_ messages: [Message]) async -> String {
        var formattedMessages: [String] = []
        
        for msg in messages {
            let role = msg.role == .user ? "User" : "Assistant"
            var content = msg.content
            
            // Add file indicators with descriptions so the summary captures file context
            if let imageFile = msg.imageFileName {
                let desc = await FileDescriptionService.shared.get(filename: imageFile)
                let descPart = desc.map { " - \"\($0)\"" } ?? ""
                content = "[Image: \(imageFile)\(descPart)] " + content
            }
            if let docFile = msg.documentFileName {
                let desc = await FileDescriptionService.shared.get(filename: docFile)
                let descPart = desc.map { " - \"\($0)\"" } ?? ""
                content = "[Document: \(docFile)\(descPart)] " + content
            }
            
            formattedMessages.append("[\(role)]: \(content)")
        }
        
        return formattedMessages.joined(separator: "\n\n")
    }
    
    private func formatDateRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }
    
    private func formatMessagesForSearch(_ messages: [Message]) async -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        
        var formattedMessages: [String] = []
        
        for msg in messages {
            let role = msg.role == .user ? "User" : "Assistant"
            let time = dateFormatter.string(from: msg.timestamp)
            var content = msg.content
            
            // Add file indicators with descriptions for full context
            if let imageFile = msg.imageFileName {
                let desc = await FileDescriptionService.shared.get(filename: imageFile)
                let descPart = desc.map { " - \"\($0)\"" } ?? ""
                content = "[Image: \(imageFile)\(descPart)] " + content
            }
            if let docFile = msg.documentFileName {
                let desc = await FileDescriptionService.shared.get(filename: docFile)
                let descPart = desc.map { " - \"\($0)\"" } ?? ""
                content = "[Document: \(docFile)\(descPart)] " + content
            }
            
            formattedMessages.append("[\(time)] \(role): \(content)")
        }
        
        return formattedMessages.joined(separator: "\n\n")
    }
    
    private func extractFirstJSONObjectData(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        for i in text.indices[start...] {
            if text[i] == "{" { depth += 1 }
            else if text[i] == "}" { depth -= 1; if depth == 0 { end = i; break } }
        }
        guard let endIdx = end else { return nil }
        return String(text[start...endIdx]).data(using: .utf8)
    }
    
    // MARK: - Persistence
    
    private func loadIndex() {
        guard FileManager.default.fileExists(atPath: indexFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexFileURL)
            chunkIndex = try JSONDecoder().decode(ChunkIndex.self, from: data)
            print("[ArchiveService] Loaded \(chunkIndex.chunks.count) chunks from index")
        } catch {
            print("[ArchiveService] Failed to load index: \(error)")
        }
    }
    
    private func saveIndex() {
        do {
            let data = try JSONEncoder().encode(chunkIndex)
            try data.write(to: indexFileURL)
        } catch {
            print("[ArchiveService] Failed to save index: \(error)")
        }
    }
    
    private func loadPendingIndex() {
        guard FileManager.default.fileExists(atPath: pendingIndexFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: pendingIndexFileURL)
            pendingIndex = try JSONDecoder().decode(PendingChunkIndex.self, from: data)
            if !pendingIndex.pendingChunks.isEmpty {
                print("[ArchiveService] Loaded \(pendingIndex.pendingChunks.count) pending chunk(s) awaiting recovery")
            }
        } catch {
            print("[ArchiveService] Failed to load pending index: \(error)")
        }
    }
    
    private func savePendingIndex() {
        do {
            let data = try JSONEncoder().encode(pendingIndex)
            try data.write(to: pendingIndexFileURL)
        } catch {
            print("[ArchiveService] Failed to save pending index: \(error)")
        }
    }
}

// MARK: - Errors

enum ArchiveError: LocalizedError {
    case emptyMessages
    case chunkNotFound
    case fileNotFound(path: String)
    case notConfigured
    case apiError
    
    var errorDescription: String? {
        switch self {
        case .emptyMessages: return "Cannot archive empty message list"
        case .chunkNotFound: return "Chunk not found in archive"
        case .fileNotFound(let path): return "Chunk file not found at: \(path)"
        case .notConfigured: return "Archive service not configured with API key"
        case .apiError: return "API call failed"
        }
    }
}
