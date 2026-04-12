import Foundation
import SwiftUI

@MainActor
class ConversationManager: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isPolling: Bool = false
    @Published var statusMessage: String = "Not started"
    @Published var error: String?
    @Published var isPrivacyModeEnabled: Bool = false
    
    private let telegramService = TelegramBotService()
    private let openRouterService = OpenRouterService()
    private let toolExecutor = ToolExecutor()
    private let archiveService = ConversationArchiveService()
    
    private var pollingTask: Task<Void, Never>?
    private var activeProcessingTask: Task<Void, Never>?
    private var activeRunId: UUID?
    private var pairedChatId: Int?
    
    // Pending media buffer - media is buffered until text triggers processing
    private var pendingImages: [(fileName: String, fileSize: Int)] = []
    private var pendingDocuments: [(fileName: String, fileSize: Int)] = []
    private var pendingReferencedImages: [(fileName: String, fileSize: Int)] = []
    private var pendingReferencedDocuments: [(fileName: String, fileSize: Int)] = []
    private var pendingForwardContext: String?
    private var pendingReplyContext: String?
    private let toolRunLogPrefix = "[TOOL RUN LOG - compact]"
    private let maxRetainedToolRunLogs = 5
    private let maxAssistantMessageChars = 4000
    private let defaultToolSpendLimitPerTurnUSD = 0.20
    private let minimumToolSpendLimitPerTurnUSD = 0.001
    private let maxToolRoundsSafetyLimit = 120
    private let shouldResumePollingDefaultsKey = "should_resume_polling_on_launch"
    private let privacyModeDefaultsKey = "telegram_privacy_mode_enabled"
    private let systemPromptTimestampKey = "system_prompt_cache_epoch"
    private let defaultMaxContextTokens = 100_000
    private let defaultTargetContextTokens = 50_000

    private struct ToolAwareResponse {
        let finalText: String
        let compactToolLog: String?
        let toolInteractions: [ToolInteraction]
        let accessedProjects: [String]?
    }

    private struct SpendLimitStatus {
        let todaySpentUSD: Double
        let monthSpentUSD: Double
        let dailyBaseLimitUSD: Double?
        let monthlyBaseLimitUSD: Double?
        let dailyExtraUSD: Double
        let monthlyExtraUSD: Double

        var effectiveDailyLimitUSD: Double? {
            dailyBaseLimitUSD.map { $0 + dailyExtraUSD }
        }

        var effectiveMonthlyLimitUSD: Double? {
            monthlyBaseLimitUSD.map { $0 + monthlyExtraUSD }
        }

        var dailyExceeded: Bool {
            effectiveDailyLimitUSD.map { todaySpentUSD >= $0 } ?? false
        }

        var monthlyExceeded: Bool {
            effectiveMonthlyLimitUSD.map { monthSpentUSD >= $0 } ?? false
        }
    }

    private struct ProjectToolTurnState {
        var createdProjectIDs: Set<String> = []
        var projectsWithSuccessfulHistory: Set<String> = []
        var projectsWithSuccessfulDeploymentHistory: Set<String> = []
    }
    
    private let appFolder: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    
    private var conversationFileURL: URL {
        appFolder.appendingPathComponent("conversation.json")
    }
    
    private var imagesDirectory: URL {
        let dir = appFolder.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    var documentsDirectory: URL {
        let dir = appFolder.appendingPathComponent("documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    init() {
        isPrivacyModeEnabled = UserDefaults.standard.bool(forKey: privacyModeDefaultsKey)
        loadConversation()

        // Ensure the system project exists for general-purpose machine operations
        Task { await toolExecutor.ensureSystemProject() }

        // Wire up archive status notifications to Telegram
        let telegramSvc = telegramService
        let archiveSvc = archiveService
        Task { @MainActor [weak self] in
            guard let self else { return }
            let chatId = self.pairedChatId
            await archiveSvc.setStatusNotificationHandler { message in
                guard let chatId else { return }
                Task { try? await telegramSvc.sendMessage(chatId: chatId, text: message) }
            }
        }

        if shouldResumePollingOnLaunch && hasRequiredPollingConfiguration() {
            Task { [weak self] in
                await self?.startPolling()
            }
        }
    }

    private func currentVoiceTranscriptionProvider() -> VoiceTranscriptionProvider {
        VoiceTranscriptionProvider.fromStoredValue(
            KeychainHelper.load(key: KeychainHelper.voiceTranscriptionProviderKey)
        )
    }

    private func openAITranscriptionAPIKey() -> String {
        (KeychainHelper.load(key: KeychainHelper.openAITranscriptionApiKeyKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configuredGeminiImageModel() -> String {
        let configuredModel = (KeychainHelper.load(key: KeychainHelper.geminiImageModelKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configuredModel.isEmpty ? GeminiImagePricing.defaultModel : configuredModel
    }

    private func configuredGeminiImagePricing() -> GeminiImagePricing {
        func configuredRate(for key: String, defaultValue: Double) -> Double {
            guard let rawValue = KeychainHelper.load(key: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  let parsed = Double(rawValue),
                  parsed.isFinite,
                  parsed >= 0 else {
                return defaultValue
            }
            return parsed
        }

        return GeminiImagePricing(
            inputCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.inputCostPerMillionTokensUSD
            ),
            outputTextCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.outputTextCostPerMillionTokensUSD
            ),
            outputImageCostPerMillionTokensUSD: configuredRate(
                for: KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey,
                defaultValue: GeminiImagePricing.default.outputImageCostPerMillionTokensUSD
            )
        )
    }
    
    // MARK: - Configuration
    
    func configure() async {
        let currentLLMProvider = LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey))
        guard let token = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey),
              let chatIdString = KeychainHelper.load(key: KeychainHelper.telegramChatIdKey),
              let chatId = Int(chatIdString) else {
            error = "Please configure Telegram settings first"
            return
        }
        let apiKey = KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? ""
        if currentLLMProvider == .openRouter && apiKey.isEmpty {
            error = "Please configure your OpenRouter API key"
            return
        }
        
        // Get optional web search keys
        let serperKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""
        let jinaKey = KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey) ?? ""
        
        pairedChatId = chatId
        await telegramService.configure(token: token)
        await openRouterService.configure(apiKey: apiKey)
        
        // Configure tool executor if web search keys are available
        if !serperKey.isEmpty {
            await toolExecutor.configure(openRouterKey: apiKey, serperKey: serperKey, jinaKey: jinaKey)
        }
        
        // Configure archive service and recover any pending chunks from previous crash
        await archiveService.configure(apiKey: apiKey)
        let recoveryChunkSummaries = await archiveService.getPromptSummaryItems(recentConsolidatedCount: 5)
        let recoveryContext = buildSummarizationContext(
            chunkSummaries: recoveryChunkSummaries,
            currentMessages: messages
        )
        await archiveService.recoverPendingChunks(defaultContext: recoveryContext)
        
        // Configure email service: prefer Gmail OAuth if authenticated, fall back to IMAP
        let gmailAuthenticated = await GmailService.shared.isAuthenticated
        
        if gmailAuthenticated {
            // Use Gmail API with OAuth
            print("[ConversationManager] Using Gmail API for email (OAuth authenticated)")
            await GmailService.shared.startBackgroundFetch()
            
            // Register handler for smart Gmail notifications
            await GmailService.shared.setNewEmailHandler { [weak self] newEmails in
                await self?.processNewGmailEmails(newEmails)
            }
        } else if let imapHost = KeychainHelper.load(key: KeychainHelper.imapHostKey),
           let imapPortStr = KeychainHelper.load(key: KeychainHelper.imapPortKey),
           let smtpHost = KeychainHelper.load(key: KeychainHelper.smtpHostKey),
           let smtpPortStr = KeychainHelper.load(key: KeychainHelper.smtpPortKey),
           let emailUsername = KeychainHelper.load(key: KeychainHelper.imapUsernameKey),
           let emailPassword = KeychainHelper.load(key: KeychainHelper.imapPasswordKey) {
            // Fall back to IMAP/SMTP
            print("[ConversationManager] Using IMAP/SMTP for email")
            let displayName = KeychainHelper.load(key: KeychainHelper.emailDisplayNameKey) ?? emailUsername
            await EmailService.shared.configure(
                imapHost: imapHost,
                imapPort: Int(imapPortStr) ?? 993,
                smtpHost: smtpHost,
                smtpPort: Int(smtpPortStr) ?? 465,
                username: emailUsername,
                password: emailPassword,
                displayName: displayName
            )
            // Start background email fetch (every 5 minutes)
            await EmailService.shared.startBackgroundFetch()
            
            // Register handler for smart email notifications (runs in detached task)
            await EmailService.shared.setNewEmailHandler { [weak self] newEmails in
                await self?.processNewEmails(newEmails)
            }
        }
        
        // Configure Gemini image service if API key is available
        if let geminiApiKey = KeychainHelper.load(key: KeychainHelper.geminiApiKeyKey), !geminiApiKey.isEmpty {
            await GeminiImageService.shared.configure(
                apiKey: geminiApiKey,
                model: configuredGeminiImageModel(),
                pricing: configuredGeminiImagePricing()
            )
        }
        
        error = nil
    }
    
    // MARK: - Polling Control
    
    func startPolling() async {
        // Prevent duplicate polling tasks
        guard !isPolling else {
            print("[ConversationManager] Polling already running, ignoring duplicate start")
            return
        }
        
        await configure()
        
        guard error == nil else { return }
        
        isPolling = true
        shouldResumePollingOnLaunch = true
        statusMessage = "Polling for messages..."
        
        // Warm up Whisper only when local transcription is active.
        if currentVoiceTranscriptionProvider() == .local {
            Task {
                await WhisperKitService.shared.checkModelStatus()
            }
        }
        
        pollingTask = Task {
            while !Task.isCancelled && isPolling {
                do {
                    // Check for due reminders first
                    await checkDueReminders()
                    
                    let updates = try await telegramService.getUpdates()
                    
                    for update in updates {
                        await processUpdate(update)
                    }
                    
                    statusMessage = "Listening... (Last check: \(formattedTime()))"
                    
                    // Poll every 1 second
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    if !Task.isCancelled {
                        statusMessage = "Error: \(error.localizedDescription)"
                        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds before retry
                    }
                }
            }
        }
    }
    
    func stopPolling() {
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        activeRunId = nil
        Task { await toolExecutor.cancelAllRunningProcesses() }
        ToolExecutor.clearPendingToolOutputs()
        
        isPolling = false
        shouldResumePollingOnLaunch = false
        pollingTask?.cancel()
        pollingTask = nil
        statusMessage = "Stopped"
    }

    private var shouldResumePollingOnLaunch: Bool {
        get {
            if UserDefaults.standard.object(forKey: shouldResumePollingDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: shouldResumePollingDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: shouldResumePollingDefaultsKey)
        }
    }

    private func hasRequiredPollingConfiguration() -> Bool {
        guard let token = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey),
              let chatIdString = KeychainHelper.load(key: KeychainHelper.telegramChatIdKey),
              let apiKey = KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) else {
            return false
        }

        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !chatIdString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    // MARK: - Message Processing
    
    private func processUpdate(_ update: TelegramUpdate) async {
        // Clear any previous error when starting to process a new message
        error = nil
        
        guard let telegramMessage = update.message else {
            return
        }
        
        // Only process messages from the paired chat
        guard telegramMessage.chat.id == pairedChatId else {
            return
        }
        
        // Skip messages from the bot itself
        if telegramMessage.from?.isBot == true {
            return
        }
        
        if let text = telegramMessage.text,
           await handleControlCommandIfNeeded(text) {
            return
        }
        
        if activeRunId != nil {
            if let chatId = pairedChatId {
                try? await telegramService.sendMessage(
                    chatId: chatId,
                    text: "⏳ I'm still working on your previous request. Send /stop to interrupt it."
                )
            }
            return
        }
        
        // Extract forward context if this is a forwarded message (accumulate with pending)
        if telegramMessage.isForwarded {
            var forwardSource = "unknown"
            
            if let origin = telegramMessage.forwardOrigin {
                forwardSource = origin.description
            } else if let fromUser = telegramMessage.forwardFrom {
                let name = [fromUser.firstName, fromUser.lastName].compactMap { $0 }.joined(separator: " ")
                forwardSource = name.isEmpty ? "a user" : name
            } else if let fromChat = telegramMessage.forwardFromChat {
                forwardSource = fromChat.title ?? "a chat"
            }
            
            let newForwardContext = "[Forwarded from \(forwardSource)]"
            if let existing = pendingForwardContext {
                pendingForwardContext = existing + "\n" + newForwardContext
            } else {
                pendingForwardContext = newForwardContext
            }
            print("[ConversationManager] User forwarded message from: \(forwardSource)")
        }
        
        // Extract reply context if user is replying to a previous message
        if let replyToMsg = telegramMessage.replyToMessage {
            var replyContent = ""
            
            if let text = replyToMsg.text, !text.isEmpty {
                replyContent = text
            } else if let caption = replyToMsg.caption, !caption.isEmpty {
                replyContent = caption
            } else if replyToMsg.photo != nil {
                replyContent = "[Image]"
            } else if let doc = replyToMsg.document {
                replyContent = "[Document: \(doc.fileName ?? "file")]"
            } else if replyToMsg.voice != nil {
                replyContent = "[Voice message]"
            } else if let video = replyToMsg.video {
                replyContent = "[Video: \(video.duration)s]"
            }
            
            if !replyContent.isEmpty {
                let senderInfo: String
                if replyToMsg.from?.isBot == true {
                    senderInfo = "your previous message"
                } else {
                    senderInfo = "their previous message"
                }
                let newReplyContext = "[Replying to \(senderInfo): \"\(replyContent)\"]"
                if let existing = pendingReplyContext {
                    pendingReplyContext = existing + "\n" + newReplyContext
                } else {
                    pendingReplyContext = newReplyContext
                }
                print("[ConversationManager] User replied to: \(replyContent.prefix(100))")
            }
            
            // Download attachments from replied-to message (add to pending referenced)
            if let photos = replyToMsg.photo, !photos.isEmpty {
                statusMessage = "Downloading referenced image..."
                let largestPhoto = photos.max(by: { $0.width * $0.height < $1.width * $1.height })!
                
                do {
                    let imageData = try await telegramService.downloadPhoto(fileId: largestPhoto.fileId)
                    let fileName = "ref_\(UUID().uuidString.prefix(8)).jpg"
                    let fileURL = imagesDirectory.appendingPathComponent(fileName)
                    try imageData.write(to: fileURL)
                    
                    pendingReferencedImages.append((fileName: fileName, fileSize: imageData.count))
                    print("[ConversationManager] Buffered referenced image: \(fileName) (\(imageData.count) bytes)")
                } catch {
                    print("[ConversationManager] Failed to download referenced image: \(error)")
                }
            }
            
            if let document = replyToMsg.document {
                statusMessage = "Downloading referenced document..."
                
                do {
                    let documentData = try await telegramService.downloadDocument(fileId: document.fileId)
                    let originalName = document.fileName ?? "document"
                    let ext = URL(fileURLWithPath: originalName).pathExtension
                    let fileName = "ref_\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "bin" : ext)"
                    let fileURL = documentsDirectory.appendingPathComponent(fileName)
                    try documentData.write(to: fileURL)
                    
                    pendingReferencedDocuments.append((fileName: fileName, fileSize: documentData.count))
                    print("[ConversationManager] Buffered referenced document: \(fileName) (\(originalName), \(documentData.count) bytes)")
                } catch {
                    print("[ConversationManager] Failed to download referenced document: \(error)")
                }
            }
            
            // Download referenced video if user replied to a video message
            if let video = replyToMsg.video {
                statusMessage = "Downloading referenced video..."
                
                do {
                    let videoData = try await telegramService.downloadDocument(fileId: video.fileId)
                    let ext: String
                    if let mimeType = video.mimeType {
                        switch mimeType {
                        case "video/mp4": ext = "mp4"
                        case "video/quicktime": ext = "mov"
                        case "video/webm": ext = "webm"
                        default: ext = "mp4"
                        }
                    } else {
                        ext = "mp4"
                    }
                    let fileName = "ref_\(UUID().uuidString.prefix(8)).\(ext)"
                    let fileURL = documentsDirectory.appendingPathComponent(fileName)
                    try videoData.write(to: fileURL)
                    
                    pendingReferencedDocuments.append((fileName: fileName, fileSize: videoData.count))
                    print("[ConversationManager] Buffered referenced video: \(fileName) (\(videoData.count) bytes)")
                } catch {
                    print("[ConversationManager] Failed to download referenced video: \(error)")
                }
            }
        }
        
        // Determine what type of message this is and whether to trigger processing
        var triggerText: String? = nil
        
        // Text message → triggers processing
        if let text = telegramMessage.text, !text.isEmpty {
            triggerText = text
        }
        // Photo message
        else if let photos = telegramMessage.photo, !photos.isEmpty {
            statusMessage = "Downloading image..."
            
            let largestPhoto = photos.max(by: { $0.width * $0.height < $1.width * $1.height })!
            
            do {
                let imageData = try await telegramService.downloadPhoto(fileId: largestPhoto.fileId)
                
                let fileName = "\(UUID().uuidString.prefix(8)).jpg"
                let fileURL = imagesDirectory.appendingPathComponent(fileName)
                try imageData.write(to: fileURL)
                
                // Also save to documents directory for email attachments
                let documentsFileURL = documentsDirectory.appendingPathComponent(fileName)
                try imageData.write(to: documentsFileURL)
                
                pendingImages.append((fileName: fileName, fileSize: imageData.count))
                print("[ConversationManager] Buffered image: \(fileName) (\(imageData.count) bytes)")
                
                // Caption triggers processing; no caption means buffer only
                if let caption = telegramMessage.caption, !caption.isEmpty {
                    triggerText = caption
                }
            } catch {
                self.error = "Failed to download image: \(error.localizedDescription)"
                statusMessage = "Image download failed"
                return
            }
        }
        // Voice message → transcription triggers processing
        else if let voice = telegramMessage.voice {
            let transcriptionProvider = currentVoiceTranscriptionProvider()
            statusMessage = transcriptionProvider == .openAI
                ? "Transcribing audio with OpenAI..."
                : "Transcribing audio locally..."
            
            do {
                let audioURL = try await telegramService.downloadVoiceFile(fileId: voice.fileId)
                defer { try? FileManager.default.removeItem(at: audioURL) }

                let transcription: String?
                switch transcriptionProvider {
                case .openAI:
                    let apiKey = openAITranscriptionAPIKey()
                    guard !apiKey.isEmpty else {
                        self.error = "OpenAI API key not set. Add it in Settings > Voice Transcription."
                        statusMessage = "OpenAI API key missing"
                        return
                    }
                    transcription = await OpenAITranscriptionService.shared.transcribeAudioFile(url: audioURL, apiKey: apiKey)
                case .local:
                    guard WhisperKitService.shared.isModelReady else {
                        self.error = "Voice model not ready. Please download it in Settings."
                        statusMessage = "Voice model not ready"
                        return
                    }
                    transcription = await WhisperKitService.shared.transcribeAudioFile(url: audioURL)
                }

                if let transcription {
                    triggerText = transcription
                    print("[ConversationManager] Transcribed voice: \(transcription)")
                } else {
                    self.error = "Failed to transcribe audio"
                    statusMessage = "Transcription failed"
                    return
                }
            } catch {
                self.error = "Failed to download voice file: \(error.localizedDescription)"
                statusMessage = "Voice download failed"
                return
            }
        }
        // Document message
        else if let document = telegramMessage.document {
            statusMessage = "Downloading document..."
            
            do {
                let documentData = try await telegramService.downloadDocument(fileId: document.fileId)
                
                let originalName = document.fileName ?? "document"
                let ext = URL(fileURLWithPath: originalName).pathExtension
                let fileName = "\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "bin" : ext)"
                let fileURL = documentsDirectory.appendingPathComponent(fileName)
                try documentData.write(to: fileURL)
                
                pendingDocuments.append((fileName: fileName, fileSize: documentData.count))
                print("[ConversationManager] Buffered document: \(fileName) (\(originalName), \(documentData.count) bytes)")
                
                // Caption triggers processing; no caption means buffer only
                if let caption = telegramMessage.caption, !caption.isEmpty {
                    triggerText = caption
                }
            } catch {
                self.error = "Failed to download document: \(error.localizedDescription)"
                statusMessage = "Document download failed"
                return
            }
        }
        // Video message - treated as a document for storage and email purposes
        else if let video = telegramMessage.video {
            statusMessage = "Downloading video..."
            
            do {
                let videoData = try await telegramService.downloadDocument(fileId: video.fileId)
                
                // Use original filename if available, otherwise generate one with proper extension
                let ext: String
                if let mimeType = video.mimeType {
                    switch mimeType {
                    case "video/mp4": ext = "mp4"
                    case "video/quicktime": ext = "mov"
                    case "video/webm": ext = "webm"
                    case "video/x-matroska": ext = "mkv"
                    default: ext = "mp4"
                    }
                } else {
                    ext = "mp4"
                }
                
                let fileName = video.fileName ?? "\(UUID().uuidString.prefix(8)).\(ext)"
                let fileURL = documentsDirectory.appendingPathComponent(fileName)
                try videoData.write(to: fileURL)
                
                pendingDocuments.append((fileName: fileName, fileSize: videoData.count))
                print("[ConversationManager] Buffered video: \(fileName) (\(videoData.count) bytes, \(video.duration)s, \(video.width)x\(video.height))")
                
                // Caption triggers processing; no caption means buffer only
                if let caption = telegramMessage.caption, !caption.isEmpty {
                    triggerText = caption
                }
            } catch {
                self.error = "Failed to download video: \(error.localizedDescription)"
                statusMessage = "Video download failed"
                return
            }
        }
        
        // If no trigger text, just show status and return (media is buffered)
        guard let promptText = triggerText else {
            let imageCount = pendingImages.count
            let docCount = pendingDocuments.count
            if imageCount > 0 || docCount > 0 {
                var parts: [String] = []
                if imageCount > 0 { parts.append("\(imageCount) image\(imageCount > 1 ? "s" : "")") }
                if docCount > 0 { parts.append("\(docCount) file\(docCount > 1 ? "s" : "")") }
                statusMessage = "📎 \(parts.joined(separator: ", ")) waiting for your message..."
            }
            return
        }
        
        // Build message content with forward and reply context
        var messageContent = promptText
        if let fwdContext = pendingForwardContext {
            messageContent = fwdContext + "\n\n" + messageContent
        }
        if let replyCtx = pendingReplyContext {
            messageContent = replyCtx + "\n\n" + messageContent
        }
        
        // Combine all pending media into the message
        let userMessage = Message(
            role: .user,
            content: messageContent,
            imageFileNames: pendingImages.map { $0.fileName },
            documentFileNames: pendingDocuments.map { $0.fileName },
            imageFileSizes: pendingImages.map { $0.fileSize },
            documentFileSizes: pendingDocuments.map { $0.fileSize },
            referencedImageFileNames: pendingReferencedImages.map { $0.fileName },
            referencedDocumentFileNames: pendingReferencedDocuments.map { $0.fileName },
            referencedDocumentFileSizes: pendingReferencedDocuments.map { $0.fileSize }
        )
        
        // Clear all buffers
        pendingImages.removeAll()
        pendingDocuments.removeAll()
        pendingReferencedImages.removeAll()
        pendingReferencedDocuments.removeAll()
        pendingForwardContext = nil
        pendingReplyContext = nil
        
        messages.append(userMessage)
        saveConversation()
        
        statusMessage = "Generating response..."
        startActiveProcessing(for: userMessage)
    }

    private func startActiveProcessing(
        for userMessage: Message,
        postRunUserMessageContent: String? = nil
    ) {
        guard activeRunId == nil, activeProcessingTask == nil else {
            print("[ConversationManager] Ignoring startActiveProcessing because a run is already active")
            return
        }
        
        let runId = UUID()
        activeRunId = runId
        
        activeProcessingTask = Task { [weak self] in
            await self?.runActiveProcessing(
                for: userMessage,
                runId: runId,
                postRunUserMessageContent: postRunUserMessageContent
            )
        }
    }
    
    private func runActiveProcessing(
        for userMessage: Message,
        runId: UUID,
        postRunUserMessageContent: String?
    ) async {
        func compactStoredEmailPromptIfNeeded() -> Bool {
            guard let compacted = postRunUserMessageContent else { return false }
            return replaceMessageContent(for: userMessage.id, with: compacted)
        }

        defer {
            if compactStoredEmailPromptIfNeeded() {
                saveConversation()
            }
            if activeRunId == runId {
                activeRunId = nil
                activeProcessingTask = nil
            }
        }
        
        do {
            let turnStartDate = Date()
            try Task.checkCancellation()
            let response = try await generateResponseWithTools(currentUserMessageId: userMessage.id, turnStartDate: turnStartDate)
            try Task.checkCancellation()
            
            guard activeRunId == runId else { return }
            
            var didMutateHistory = false

            // Add assistant message with tool interactions, compact log, downloaded files, and accessed projects
            let finalResponseRaw = response.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "I completed the requested actions."
                : response.finalText
            let finalResponse = capAssistantMessageForHistoryAndTelegram(finalResponseRaw)
            let downloadedFilenames = ToolExecutor.getPendingDownloadedFilenames()
            let assistantMessage = Message(
                role: .assistant,
                content: finalResponse,
                downloadedDocumentFileNames: downloadedFilenames,
                accessedProjectIds: response.accessedProjects ?? [],
                toolInteractions: response.toolInteractions,
                compactToolLog: response.compactToolLog
            )
            messages.append(assistantMessage)
            didMutateHistory = true

            if compactStoredEmailPromptIfNeeded() {
                didMutateHistory = true
            }
            if didMutateHistory {
                saveConversation()
            }
            
            if let chatId = pairedChatId {
                try Task.checkCancellation()
                guard activeRunId == runId else { return }
                try await telegramService.sendMessage(chatId: chatId, text: finalResponse)
                
                // Send any generated images (from tool executor, renamed to avoid conflict)
                let toolGeneratedImages = ToolExecutor.getPendingImages()
                for (imageData, mimeType, prompt) in toolGeneratedImages {
                    try Task.checkCancellation()
                    guard activeRunId == runId else { return }
                    
                    do {
                        let caption = "🎨 Generated: \(prompt.prefix(200))\(prompt.count > 200 ? "..." : "")"
                        try await telegramService.sendPhoto(chatId: chatId, imageData: imageData, caption: caption, mimeType: mimeType)
                        print("[ConversationManager] Sent generated image (\(imageData.count) bytes)")
                    } catch {
                        print("[ConversationManager] Failed to send generated image: \(error)")
                    }
                }
                
                // Send any queued documents (or photos if the file is an image)
                let toolPendingDocuments = ToolExecutor.getPendingDocuments()
                for (documentData, filename, mimeType, caption) in toolPendingDocuments {
                    try Task.checkCancellation()
                    guard activeRunId == runId else { return }
                    
                    do {
                        if mimeType.hasPrefix("image/") {
                            try await telegramService.sendPhoto(chatId: chatId, imageData: documentData, caption: caption, mimeType: mimeType)
                            print("[ConversationManager] Sent image as photo: \(filename) (\(documentData.count) bytes)")
                        } else {
                            try await telegramService.sendDocument(chatId: chatId, documentData: documentData, filename: filename, caption: caption, mimeType: mimeType)
                            print("[ConversationManager] Sent document: \(filename) (\(documentData.count) bytes)")
                        }
                    } catch {
                        print("[ConversationManager] Failed to send document \(filename): \(error)")
                    }
                }
            }
            
            // Generate descriptions for files in the user message (synchronous to ensure availability)
            // This happens while context is still fresh, so descriptions will be available for future prompts
            var filesToDescribe = collectFilesForDescription(from: userMessage)
            
            // Also collect files downloaded via tools (email attachments, etc.)
            let toolDownloadedFiles = ToolExecutor.getPendingFilesForDescription()
            filesToDescribe.append(contentsOf: toolDownloadedFiles)
            
            if !filesToDescribe.isEmpty {
                do {
                    let descriptions = try await openRouterService.generateFileDescriptions(files: filesToDescribe, conversationContext: messages)
                    await FileDescriptionService.shared.saveMultiple(descriptions)
                } catch {
                    print("[ConversationManager] Failed to generate file descriptions: \(error)")
                }
            }
            
            guard activeRunId == runId else { return }
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        } catch is CancellationError {
            ToolExecutor.clearPendingToolOutputs()
            if activeRunId == runId {
                statusMessage = "Cancelled"
            }
            print("[ConversationManager] Active run cancelled")
        } catch {
            ToolExecutor.clearPendingToolOutputs()
            if activeRunId == runId {
                self.error = "Failed to generate response: \(error.localizedDescription)"
                statusMessage = "Error generating response"
            }
        }
    }
    
    private func commandToken(from text: String) -> String {
        let firstToken = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .lowercased() ?? ""
        return firstToken.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
    }
    
    private func handleControlCommandIfNeeded(_ text: String) async -> Bool {
        let token = commandToken(from: text)
        
        switch token {
        case "/stop":
            await stopActiveExecution()
            return true
        case "/spend":
            await sendSpendSnapshot()
            return true
        case "/more1":
            await increaseSpendLimitIfNeeded(by: 1)
            return true
        case "/more5":
            await increaseSpendLimitIfNeeded(by: 5)
            return true
        case "/more10":
            await increaseSpendLimitIfNeeded(by: 10)
            return true
        case "/claude":
            await switchCodeCLIProvider(to: "claude")
            return true
        case "/gemini":
            await switchCodeCLIProvider(to: "gemini")
            return true
        case "/codex":
            await switchCodeCLIProvider(to: "codex")
            return true
        case "/hide":
            await setPrivacyMode(enabled: true)
            return true
        case "/show":
            await setPrivacyMode(enabled: false)
            return true
        case "/transcribe_local":
            await switchVoiceTranscriptionProvider(to: .local)
            return true
        case "/transcribe_openai":
            await switchVoiceTranscriptionProvider(to: .openAI)
            return true
        case "/prune":
            await manualPruneToolInteractions()
            return true
        default:
            return false
        }
    }

    private func manualPruneToolInteractions() async {
        let targetTokens = configuredTargetContextTokens()
        let protectedIndex = lastAssistantIndexWithTools(in: messages)

        // Estimate current context with a rough system prompt estimate
        var totalTokens = 3000 // System prompt overhead estimate
        let persona = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        totalTokens += persona.count / 4

        var prunableToolTokens = 0
        for (i, message) in messages.enumerated() {
            totalTokens += message.content.count / 4 + 1
            totalTokens += message.imageFileNames.count * 50
            totalTokens += message.documentFileNames.count * 50
            let msgToolTokens = estimateToolInteractionTokens(message.toolInteractions)
            totalTokens += msgToolTokens
            if i != protectedIndex && message.role == .assistant && !message.toolInteractions.isEmpty {
                prunableToolTokens += msgToolTokens
            }
        }

        guard prunableToolTokens > 0 else {
            if let chatId = pairedChatId {
                try? await telegramService.sendMessage(chatId: chatId, text: "No prunable tool interactions (the latest turn is always protected).")
            }
            return
        }

        let beforeTokens = totalTokens

        var prunedCount = 0
        for i in 0..<messages.count {
            guard totalTokens > targetTokens else { break }
            guard i != protectedIndex else { continue }
            guard messages[i].role == .assistant && !messages[i].toolInteractions.isEmpty else { continue }

            let savedTokens = estimateToolInteractionTokens(messages[i].toolInteractions)
            messages[i].toolInteractions = []
            totalTokens -= savedTokens
            prunedCount += 1
        }

        if prunedCount > 0 {
            pruneOldCompactToolLogs()
            saveConversation()
            refreshSystemPromptTimestamp()
        }

        if let chatId = pairedChatId {
            let msg = prunedCount > 0
                ? "✂️ Pruned tool interactions from \(prunedCount) turn(s). Context: ~\(beforeTokens / 1000)K → ~\(totalTokens / 1000)K tokens (target: \(targetTokens / 1000)K). Latest turn protected."
                : "Context already under target (~\(totalTokens / 1000)K ≤ \(targetTokens / 1000)K). Nothing to prune."
            try? await telegramService.sendMessage(chatId: chatId, text: msg)
        }
    }
    
    private func switchCodeCLIProvider(to provider: String) async {
        let normalizedProvider = provider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        
        guard ["claude", "gemini", "codex"].contains(normalizedProvider) else {
            return
        }
        
        let currentProvider = (KeychainHelper.load(key: KeychainHelper.codeCLIProviderKey) ?? KeychainHelper.defaultCodeCLIProvider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        
        let providerDisplayName: String
        switch normalizedProvider {
        case "gemini":
            providerDisplayName = "Gemini CLI"
        case "codex":
            providerDisplayName = "Codex CLI"
        default:
            providerDisplayName = "Claude Code"
        }
        
        let message: String
        if currentProvider == normalizedProvider {
            message = "✅ Code CLI already set to \(providerDisplayName)."
        } else {
            do {
                try KeychainHelper.save(key: KeychainHelper.codeCLIProviderKey, value: normalizedProvider)
                if activeRunId != nil {
                    message = "✅ Switched Code CLI to \(providerDisplayName). It will apply to the next delegated run."
                } else {
                    message = "✅ Switched Code CLI to \(providerDisplayName)."
                }
            } catch {
                message = "❌ Failed to switch Code CLI to \(providerDisplayName): \(error.localizedDescription)"
            }
        }
        
        if let chatId = pairedChatId {
            try? await telegramService.sendMessage(chatId: chatId, text: message)
        }
        
        if activeRunId == nil {
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        }
    }

    private func switchVoiceTranscriptionProvider(to provider: VoiceTranscriptionProvider) async {
        let currentProvider = currentVoiceTranscriptionProvider()
        let providerDisplayName = provider.displayName
        let switchedMessage: String

        if currentProvider == provider {
            switchedMessage = "✅ Voice transcription already set to \(providerDisplayName)."
        } else {
            do {
                try KeychainHelper.save(
                    key: KeychainHelper.voiceTranscriptionProviderKey,
                    value: provider.rawValue
                )
                switchedMessage = "✅ Switched voice transcription to \(providerDisplayName)."
            } catch {
                let errorMessage = "❌ Failed to switch voice transcription to \(providerDisplayName): \(error.localizedDescription)"
                if let chatId = pairedChatId {
                    try? await telegramService.sendMessage(chatId: chatId, text: errorMessage)
                }
                if activeRunId == nil {
                    statusMessage = "Listening... (Last check: \(formattedTime()))"
                }
                return
            }
        }

        var advisoryNotes: [String] = []
        if provider == .openAI {
            if openAITranscriptionAPIKey().isEmpty {
                advisoryNotes.append("⚠️ OpenAI API key missing. Add it in Settings > Voice Transcription.")
            }
        } else {
            await WhisperKitService.shared.checkModelStatus()
            if !WhisperKitService.shared.isModelReady {
                advisoryNotes.append("⚠️ \(WhisperKitService.shared.statusMessage). Configure the Whisper model in Settings > Voice Transcription.")
            }
        }

        let message = ([switchedMessage] + advisoryNotes).joined(separator: "\n")
        if let chatId = pairedChatId {
            try? await telegramService.sendMessage(chatId: chatId, text: message)
        }

        if activeRunId == nil {
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        }
    }

    private func sendSpendSnapshot() async {
        let snapshot = KeychainHelper.openRouterSpendSnapshot(referenceDate: Date())
        let extra = KeychainHelper.openRouterSpendLimitIncreaseSnapshot(referenceDate: Date())
        var lines = [
            "💸 API spend",
            "Today: $\(formatUSD(snapshot.today))",
            "This month: $\(formatUSD(snapshot.month))"
        ]
        if extra.daily > 0 {
            lines.append("Today's extra limit: +$\(formatUSD(extra.daily))")
        }
        if extra.monthly > 0 {
            lines.append("This month's extra limit: +$\(formatUSD(extra.monthly))")
        }
        let message = lines.joined(separator: "\n")

        if let chatId = pairedChatId {
            try? await telegramService.sendMessage(chatId: chatId, text: message)
        }

        if activeRunId == nil {
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        }
    }

    private func setPrivacyMode(enabled: Bool) async {
        guard isPrivacyModeEnabled != enabled else {
            if let chatId = pairedChatId {
                let message = enabled
                    ? "Privacy mode is already enabled. The on-screen conversation and context viewer stay hidden until you send /show."
                    : "Privacy mode is already disabled. The conversation and context viewer are visible again."
                try? await telegramService.sendMessage(chatId: chatId, text: message)
            }

            if activeRunId == nil {
                statusMessage = "Listening... (Last check: \(formattedTime()))"
            }
            return
        }

        isPrivacyModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: privacyModeDefaultsKey)

        if let chatId = pairedChatId {
            let message = enabled
                ? "Privacy mode enabled. The macOS app now hides the conversation and disables the context viewer until you send /show."
                : "Privacy mode disabled. The macOS app shows the conversation and re-enables the context viewer."
            try? await telegramService.sendMessage(chatId: chatId, text: message)
        }

        if activeRunId == nil {
            statusMessage = enabled
                ? "Privacy mode enabled"
                : "Listening... (Last check: \(formattedTime()))"
        }
    }
    
    private func stopActiveExecution() async {
        let wasRunning = activeRunId != nil
        
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        activeRunId = nil
        
        await toolExecutor.cancelAllRunningProcesses()
        ToolExecutor.clearPendingToolOutputs()
        
        if let chatId = pairedChatId {
            let text = wasRunning
                ? "⛔ Stopped current execution."
                : "Nothing is currently running."
            try? await telegramService.sendMessage(chatId: chatId, text: text)
        }
        
        statusMessage = wasRunning ? "Cancelled" : "Listening... (Last check: \(formattedTime()))"
    }

    private func increaseSpendLimitIfNeeded(by amountUSD: Double) async {
        let status = currentSpendLimitStatus(referenceDate: Date())
        let applyToDaily = status.dailyExceeded && status.dailyBaseLimitUSD != nil
        let applyToMonthly = status.monthlyExceeded && status.monthlyBaseLimitUSD != nil

        let message: String
        if applyToDaily || applyToMonthly {
            KeychainHelper.addOpenRouterSpendLimitIncrease(
                amountUSD,
                applyToDaily: applyToDaily,
                applyToMonthly: applyToMonthly
            )

            let updatedStatus = currentSpendLimitStatus(referenceDate: Date())
            if applyToDaily, applyToMonthly {
                message = """
                ✅ Added $\(formatUSD(amountUSD)) to both reached spend limits.
                New daily limit: $\(formatUSD(updatedStatus.effectiveDailyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.todaySpentUSD)))
                New monthly limit: $\(formatUSD(updatedStatus.effectiveMonthlyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.monthSpentUSD)))
                """
            } else if applyToDaily {
                message = """
                ✅ Added $\(formatUSD(amountUSD)) to today's spend limit.
                New daily limit: $\(formatUSD(updatedStatus.effectiveDailyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.todaySpentUSD)))
                """
            } else {
                message = """
                ✅ Added $\(formatUSD(amountUSD)) to this month's spend limit.
                New monthly limit: $\(formatUSD(updatedStatus.effectiveMonthlyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.monthSpentUSD)))
                """
            }
        } else {
            message = "No daily or monthly spend limit is currently reached. `/more1`, `/more5`, and `/more10` only work after a daily or monthly cap has been hit."
        }

        if let chatId = pairedChatId {
            try? await telegramService.sendMessage(chatId: chatId, text: message)
        }

        if activeRunId == nil {
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        }
    }
    
    // MARK: - Tool-Aware Response Generation
    
    private func generateResponseWithTools(currentUserMessageId: UUID, turnStartDate: Date) async throws -> ToolAwareResponse {
        try Task.checkCancellation()
        
        // Check if tools are available
        let serperKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""
        var deploymentToolsUnlockedForTurn = false
        
        // Fetch all context data in PARALLEL for performance
        let contextStartTime = Date()
        async let calendarContextTask = CalendarService.shared.getCalendarContextForSystemPrompt()
        async let emailContextTask = EmailService.shared.getEmailContextForSystemPrompt()
        async let chunkSummariesTask = archiveService.getPromptSummaryItems(recentConsolidatedCount: 5)
        async let totalChunkCountTask = archiveService.getAllChunks()
        async let contextResultTask = openRouterService.processContextWindow(messages)
        
        // Await all parallel operations
        let calendarContext = await calendarContextTask
        let emailContext = await emailContextTask
        let chunkSummaries = await chunkSummariesTask
        let allChunks = await totalChunkCountTask
        let totalChunkCount = allChunks.count
        let contextResult = await contextResultTask
        try Task.checkCancellation()
        print("[TIMING] Context fetch took: \(String(format: "%.2f", Date().timeIntervalSince(contextStartTime)))s")
        
        // Archive messages if threshold exceeded (based on conversation text weight only)
        // Summarization is critical: we MUST complete it before proceeding to avoid data loss
        if contextResult.needsArchiving && !contextResult.messagesToArchive.isEmpty {
            let archiveStartTime = Date()
            var archived = false
            var retryCount = 0
            let baseDelay: UInt64 = 2_000_000_000 // 2 seconds
            let maxDelay: UInt64 = 60_000_000_000 // 60 seconds max

            // Notify user that summarization is in progress
            if let chatId = pairedChatId {
                try? await telegramService.sendMessage(chatId: chatId, text: "🧠 Summarizing conversation history...")
            }

            // Build full summarization context for high-quality summaries
            let summarizationContext = buildSummarizationContext(
                chunkSummaries: chunkSummaries,
                currentMessages: contextResult.messagesToSend
            )
            
            while !archived {
                try Task.checkCancellation()
                do {
                    _ = try await archiveService.archiveMessages(contextResult.messagesToArchive, context: summarizationContext)
                    print("[ConversationManager] Archived \(contextResult.messagesToArchive.count) messages successfully")
                    archived = true
                    
                    // Remove archived messages from the main conversation array
                    // They're now safely stored in chunks and available via summaries
                    let archivedCount = contextResult.messagesToArchive.count
                    messages.removeFirst(archivedCount)
                    saveConversation()
                    print("[ConversationManager] Removed \(archivedCount) archived messages from active conversation")
                } catch {
                    retryCount += 1
                    let delay = min(baseDelay * UInt64(pow(2.0, Double(min(retryCount - 1, 5)))), maxDelay)
                    print("[ConversationManager] Archive failed (attempt \(retryCount)): \(error). Retrying in \(delay / 1_000_000_000)s...")
                    
                    // Notify user that we're working on archival
                    if retryCount == 1, let chatId = pairedChatId {
                        try? await telegramService.sendMessage(chatId: chatId, text: "📦 Archiving conversation history, please wait...")
                    }
                    
                    try await Task.sleep(nanoseconds: delay)
                }
            }
            print("[TIMING] Archive took: \(String(format: "%.2f", Date().timeIntervalSince(archiveStartTime)))s")
        }

        // Prune stored tool interactions if full context exceeds budget
        let didPrune = pruneToolInteractionsIfNeeded(
            calendarContext: calendarContext,
            emailContext: emailContext,
            chunkSummaries: chunkSummaries
        )
        if didPrune {
            refreshSystemPromptTimestamp()
        }

        // Use the frozen system prompt timestamp (only refreshes on prune events or day change)
        let systemPromptDate = currentSystemPromptTimestamp()

        // Capture messages after archival + pruning for the agentic loop (var for mid-loop pruning)
        var messagesForLLM = messages

        // Tool interaction loop with per-turn, daily, and monthly spend caps (USD).
        let toolSpendLimitPerTurnUSD = configuredToolSpendLimitPerTurnUSD()
        let spendLimitStatus = currentSpendLimitStatus(referenceDate: Date())
        let toolSpendLimitDailyUSD = spendLimitStatus.effectiveDailyLimitUSD
        let toolSpendLimitMonthlyUSD = spendLimitStatus.effectiveMonthlyLimitUSD
        var cumulativeToolSpendUSD: Double = 0
        var toolInteractions: [ToolInteraction] = []
        var didHitToolSpendLimit = false
        var todaySpentUSD = spendLimitStatus.todaySpentUSD
        var monthSpentUSD = spendLimitStatus.monthSpentUSD

        if let exceededMessage = spendLimitExceededMessage(
            todaySpentUSD: todaySpentUSD,
            monthSpentUSD: monthSpentUSD,
            dailyLimitUSD: toolSpendLimitDailyUSD,
            monthlyLimitUSD: toolSpendLimitMonthlyUSD
        ) {
            print("[ConversationManager] Daily/monthly spend limit already reached before tool loop: \(exceededMessage)")
            return ToolAwareResponse(
                finalText: exceededMessage,
                compactToolLog: nil,
                toolInteractions: [],
                accessedProjects: []
            )
        }
        
        toolLoop: for round in 1...maxToolRoundsSafetyLimit {
            try Task.checkCancellation()
            print("[ConversationManager] Tool round \(round) (turn spend: $\(formatUSD(cumulativeToolSpendUSD)) / $\(formatUSD(toolSpendLimitPerTurnUSD)), today: $\(formatUSD(todaySpentUSD)), month: $\(formatUSD(monthSpentUSD)))")
            
            // Call LLM (with tools available for chaining)
            let llmStartTime = Date()
            var toolsForRound = AvailableTools.all(
                includeWebSearch: !serperKey.isEmpty,
                includeProjectDeploymentTools: deploymentToolsUnlockedForTurn
            )
            if deploymentToolsUnlockedForTurn {
                toolsForRound.removeAll { $0.function.name == "show_project_deployment_tools" }
            }
            let allowedToolNames = Set(toolsForRound.map { $0.function.name })
            let response = try await openRouterService.generateResponse(
                messages: messagesForLLM,
                imagesDirectory: imagesDirectory,
                documentsDirectory: documentsDirectory,
                tools: toolsForRound,  // Always pass tools so LLM can chain calls
                toolResultMessages: toolInteractions.isEmpty ? nil : toolInteractions,
                calendarContext: calendarContext,
                emailContext: emailContext,
                chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
                totalChunkCount: totalChunkCount,
                currentUserMessageId: currentUserMessageId,
                deploymentToolsUnlockedForTurn: deploymentToolsUnlockedForTurn,
                turnStartDate: systemPromptDate
            )
            print("[TIMING] LLM API call took: \(String(format: "%.2f", Date().timeIntervalSince(llmStartTime)))s")
            let roundSpendUSD = spendUSD(from: response)
            if let roundSpendUSD, roundSpendUSD > 0 {
                cumulativeToolSpendUSD += roundSpendUSD
                todaySpentUSD += roundSpendUSD
                monthSpentUSD += roundSpendUSD
                KeychainHelper.recordOpenRouterSpend(roundSpendUSD)
                print("[ConversationManager] Round \(round) spend: +$\(formatUSD(roundSpendUSD)) (total $\(formatUSD(cumulativeToolSpendUSD)))")
            } else {
                print("[ConversationManager] Round \(round) spend unavailable or zero")
            }
            
            switch response {
            case .text(let content, let promptTokens, _):
                // LLM decided to respond with text - we're done
                if let tokens = promptTokens {
                    print("[ConversationManager] LLM returned text response after \(round) round(s) (\(tokens) prompt tokens)")
                } else {
                    print("[ConversationManager] LLM returned text response after \(round) round(s)")
                }
                let accessedProjects = extractAccessedProjects(from: toolInteractions)
                return ToolAwareResponse(
                    finalText: content,
                    compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                    toolInteractions: toolInteractions,
                    accessedProjects: accessedProjects
                )
                
            case .toolCalls(let assistantMessage, let calls, _, _):
                // Model wants to use more tools
                print("[ConversationManager] Round \(round): LLM requested \(calls.count) tool(s): \(calls.map { $0.function.name })")
                
                if cumulativeToolSpendUSD >= toolSpendLimitPerTurnUSD {
                    didHitToolSpendLimit = true
                    statusMessage = "Spend limit reached, preparing response..."
                    print("[ConversationManager] Tool spend limit reached ($\(formatUSD(cumulativeToolSpendUSD)) >= $\(formatUSD(toolSpendLimitPerTurnUSD))); forcing final response")
                    break toolLoop
                }

                if let exceededMessage = spendLimitExceededMessage(
                    todaySpentUSD: todaySpentUSD,
                    monthSpentUSD: monthSpentUSD,
                    dailyLimitUSD: toolSpendLimitDailyUSD,
                    monthlyLimitUSD: toolSpendLimitMonthlyUSD
                ) {
                    print("[ConversationManager] Daily/monthly spend limit reached during tool loop: \(exceededMessage)")
                    return ToolAwareResponse(
                        finalText: exceededMessage,
                        compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                        toolInteractions: toolInteractions,
                        accessedProjects: extractAccessedProjects(from: toolInteractions)
                    )
                }
                
                let (executableCalls, blockedResults) = partitionToolCallsForExecution(
                    calls,
                    allowedToolNames: allowedToolNames,
                    deploymentToolsUnlockedForTurn: deploymentToolsUnlockedForTurn,
                    priorInteractions: toolInteractions,
                    historicalMessages: messagesForLLM
                )
                if !blockedResults.isEmpty {
                    print("[ConversationManager] Round \(round): blocked \(blockedResults.count) tool call(s) due to turn policy or tool availability")
                }
                
                // Send progress message to Telegram
                if let chatId = pairedChatId, !executableCalls.isEmpty {
                    let progressMessage = getProgressMessage(for: executableCalls)
                    try? await telegramService.sendMessage(chatId: chatId, text: progressMessage)
                }
                statusMessage = "Executing tools (round \(round))..."
                
                // Execute available tools only. Return explicit errors for blocked/unavailable tool calls.
                // Then reorder results to match the assistant's tool call order for deterministic follow-up prompts.
                var toolResults: [ToolResultMessage] = []
                if !executableCalls.isEmpty {
                    let executedResults = try await toolExecutor.executeParallel(executableCalls)
                    toolResults.append(contentsOf: executedResults)
                }
                if !blockedResults.isEmpty {
                    toolResults.append(contentsOf: blockedResults)
                }
                try Task.checkCancellation()
                
                var orderedToolResults: [ToolResultMessage] = []
                var remainingToolResults = toolResults
                for call in assistantMessage.toolCalls {
                    if let index = remainingToolResults.firstIndex(where: { $0.toolCallId == call.id }) {
                        orderedToolResults.append(remainingToolResults.remove(at: index))
                    }
                }
                if !remainingToolResults.isEmpty {
                    print("[ConversationManager] Round \(round): appending \(remainingToolResults.count) unmatched tool result(s) after ordered results")
                    orderedToolResults.append(contentsOf: remainingToolResults)
                }

                let toolInternalSpendUSD = toolSpendUSD(from: orderedToolResults)
                if toolInternalSpendUSD > 0 {
                    cumulativeToolSpendUSD += toolInternalSpendUSD
                    todaySpentUSD += toolInternalSpendUSD
                    monthSpentUSD += toolInternalSpendUSD
                    KeychainHelper.recordOpenRouterSpend(toolInternalSpendUSD)
                    print("[ConversationManager] Round \(round) research tool spend: +$\(formatUSD(toolInternalSpendUSD)) (total $\(formatUSD(cumulativeToolSpendUSD)))")
                }
                
                print("[ConversationManager] Round \(round) tool execution complete")
                
                // Append real-time chronology to the end of each tool result
                // This lets the model know exactly how much time passed without breaking the prompt cache prefix
                let postToolTimeFormatter = DateFormatter()
                postToolTimeFormatter.dateFormat = "HH:mm:ss"
                let currentRealTime = postToolTimeFormatter.string(from: Date())
                
                for i in 0..<orderedToolResults.count {
                    let existingContent = orderedToolResults[i].content
                    orderedToolResults[i].content = existingContent + "\n\n[System Note: Current time is now \(currentRealTime)]"
                }
                
                if executableCalls.contains(where: { $0.function.name == "show_project_deployment_tools" }) {
                    deploymentToolsUnlockedForTurn = true
                }
                
                // Add this interaction to the chain
                let interaction = ToolInteraction(
                    assistantMessage: assistantMessage,
                    results: orderedToolResults
                )
                toolInteractions.append(interaction)

                // Mid-loop: prune stored tool interactions from older turns if context is growing too large
                let _ = pruneStoredToolInteractionsMidLoop(
                    messagesForLLM: &messagesForLLM,
                    currentTurnInteractions: toolInteractions,
                    calendarContext: calendarContext,
                    emailContext: emailContext,
                    chunkSummaries: chunkSummaries
                )

                if cumulativeToolSpendUSD >= toolSpendLimitPerTurnUSD {
                    didHitToolSpendLimit = true
                    statusMessage = "Spend limit reached, preparing response..."
                    print("[ConversationManager] Tool spend limit reached after tool execution ($\(formatUSD(cumulativeToolSpendUSD)) >= $\(formatUSD(toolSpendLimitPerTurnUSD))); forcing final response")
                    break toolLoop
                }

                if let exceededMessage = spendLimitExceededMessage(
                    todaySpentUSD: todaySpentUSD,
                    monthSpentUSD: monthSpentUSD,
                    dailyLimitUSD: toolSpendLimitDailyUSD,
                    monthlyLimitUSD: toolSpendLimitMonthlyUSD
                ) {
                    print("[ConversationManager] Daily/monthly spend limit reached after tool execution: \(exceededMessage)")
                    return ToolAwareResponse(
                        finalText: exceededMessage,
                        compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                        toolInteractions: toolInteractions,
                        accessedProjects: extractAccessedProjects(from: toolInteractions)
                    )
                }
                
                statusMessage = "Processing results..."
            }
        }
        
        let didHitSafetyLimit = !didHitToolSpendLimit
        if didHitSafetyLimit {
            print("[ConversationManager] Safety tool round limit (\(maxToolRoundsSafetyLimit)) reached, forcing final response")
        }

        // Force one final call WITHOUT tools to produce a user-facing response
        let finalResponseInstruction: String
        if didHitToolSpendLimit {
            finalResponseInstruction = """
            The tool spend limit for this turn has been reached (spent approximately $\(formatUSD(cumulativeToolSpendUSD)), limit $\(formatUSD(toolSpendLimitPerTurnUSD))).
            Provide the best possible final response to the user using the information you already have. Do not call additional tools.
            """
        } else {
            finalResponseInstruction = """
            You have reached the tool-round safety limit for this turn.
            Provide the best possible final response to the user using the information you already have. Do not call additional tools.
            """
        }

        try Task.checkCancellation()
        let finalResponse = try await openRouterService.generateResponse(
            messages: messagesForLLM,
            imagesDirectory: imagesDirectory,
            documentsDirectory: documentsDirectory,
            tools: nil,  // No tools to force text response
            toolResultMessages: toolInteractions,
            calendarContext: calendarContext,
            emailContext: emailContext,
            chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
            totalChunkCount: totalChunkCount,
            currentUserMessageId: currentUserMessageId,
            deploymentToolsUnlockedForTurn: deploymentToolsUnlockedForTurn,
            turnStartDate: systemPromptDate,
            finalResponseInstruction: finalResponseInstruction
        )
        if let finalSpendUSD = spendUSD(from: finalResponse), finalSpendUSD > 0 {
            KeychainHelper.recordOpenRouterSpend(finalSpendUSD)
        }
        
        let accessedProjects = extractAccessedProjects(from: toolInteractions)
        
        switch finalResponse {
        case .text(let content, _, _):
            return ToolAwareResponse(
                finalText: content,
                compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                toolInteractions: toolInteractions,
                accessedProjects: accessedProjects
            )
        case .toolCalls(_, _, _, _):
            return ToolAwareResponse(
                finalText: "I completed the requested actions but had trouble summarizing the results.",
                compactToolLog: buildCompactToolExecutionLog(from: toolInteractions),
                toolInteractions: toolInteractions,
                accessedProjects: accessedProjects
            )
        }
    }
    
    private func configuredToolSpendLimitPerTurnUSD() -> Double {
        guard let rawValue = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let parsed = Double(rawValue),
              parsed.isFinite,
              parsed >= minimumToolSpendLimitPerTurnUSD else {
            return defaultToolSpendLimitPerTurnUSD
        }
        return parsed
    }

    private func configuredDailyToolSpendLimitUSD() -> Double? {
        guard let rawValue = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let parsed = Double(rawValue),
              parsed.isFinite,
              parsed >= minimumToolSpendLimitPerTurnUSD else {
            return nil
        }
        return parsed
    }

    private func configuredMonthlyToolSpendLimitUSD() -> Double? {
        guard let rawValue = KeychainHelper.load(key: KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let parsed = Double(rawValue),
              parsed.isFinite,
              parsed >= minimumToolSpendLimitPerTurnUSD else {
            return nil
        }
        return parsed
    }

    private func currentSpendLimitStatus(referenceDate: Date = Date()) -> SpendLimitStatus {
        let spendSnapshot = KeychainHelper.openRouterSpendSnapshot(referenceDate: referenceDate)
        let extraSnapshot = KeychainHelper.openRouterSpendLimitIncreaseSnapshot(referenceDate: referenceDate)
        return SpendLimitStatus(
            todaySpentUSD: spendSnapshot.today,
            monthSpentUSD: spendSnapshot.month,
            dailyBaseLimitUSD: configuredDailyToolSpendLimitUSD(),
            monthlyBaseLimitUSD: configuredMonthlyToolSpendLimitUSD(),
            dailyExtraUSD: extraSnapshot.daily,
            monthlyExtraUSD: extraSnapshot.monthly
        )
    }

    private func spendLimitExceededMessage(
        todaySpentUSD: Double,
        monthSpentUSD: Double,
        dailyLimitUSD: Double?,
        monthlyLimitUSD: Double?
    ) -> String? {
        let dailyExceeded = dailyLimitUSD.map { todaySpentUSD >= $0 } ?? false
        let monthlyExceeded = monthlyLimitUSD.map { monthSpentUSD >= $0 } ?? false
        guard dailyExceeded || monthlyExceeded else { return nil }

        if dailyExceeded, monthlyExceeded, let dailyLimitUSD, let monthlyLimitUSD {
            return "I paused tool usage because both spend limits were reached (today: $\(formatUSD(todaySpentUSD)) / $\(formatUSD(dailyLimitUSD)); this month: $\(formatUSD(monthSpentUSD)) / $\(formatUSD(monthlyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or raise the limits in Settings > OpenRouter."
        }
        if dailyExceeded, let dailyLimitUSD {
            return "I paused tool usage because the daily spend limit was reached (today: $\(formatUSD(todaySpentUSD)) / $\(formatUSD(dailyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or raise it in Settings > OpenRouter."
        }
        if monthlyExceeded, let monthlyLimitUSD {
            return "I paused tool usage because the monthly spend limit was reached (this month: $\(formatUSD(monthSpentUSD)) / $\(formatUSD(monthlyLimitUSD))). Reply `/more1`, `/more5`, or `/more10` to temporarily raise the reached limit and keep going, or raise it in Settings > OpenRouter."
        }
        return nil
    }
    
    private func spendUSD(from response: LLMResponse) -> Double? {
        switch response {
        case .text(_, _, let spendUSD):
            return spendUSD
        case .toolCalls(_, _, _, let spendUSD):
            return spendUSD
        }
    }

    private func toolSpendUSD(from results: [ToolResultMessage]) -> Double {
        results
            .compactMap(\.spendUSD)
            .filter { $0.isFinite && $0 > 0 }
            .reduce(0, +)
    }

    // MARK: - Context Budget & Tool Interaction Pruning

    private func configuredMaxContextTokens() -> Int {
        if let raw = KeychainHelper.load(key: KeychainHelper.maxContextTokensKey),
           let value = Int(raw), value >= 10000 {
            return value
        }
        return defaultMaxContextTokens
    }

    private func configuredTargetContextTokens() -> Int {
        if let raw = KeychainHelper.load(key: KeychainHelper.targetContextTokensKey),
           let value = Int(raw), value >= 5000 {
            return value
        }
        return defaultTargetContextTokens
    }

    /// Estimate tokens for tool interactions (assistant tool_calls + tool results)
    private func estimateToolInteractionTokens(_ interactions: [ToolInteraction]) -> Int {
        var tokens = 0
        for interaction in interactions {
            tokens += (interaction.assistantMessage.content?.count ?? 0) / 4
            for call in interaction.assistantMessage.toolCalls {
                tokens += call.function.arguments.count / 4
                tokens += call.function.name.count / 4 + 20
            }
            for result in interaction.results {
                tokens += result.content.count / 4 + 20
            }
        }
        return tokens
    }

    /// Estimate system prompt size from its components
    private func estimateSystemPromptTokens(
        calendarContext: String?,
        emailContext: String?,
        chunkSummaries: [ArchivedSummaryItem]
    ) -> Int {
        var chars = 3000 // Fixed instruction overhead
        let persona = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        chars += persona.count
        if let cal = calendarContext { chars += cal.count }
        if let email = emailContext { chars += email.count }
        for summary in chunkSummaries {
            chars += summary.summary.count + 100
        }
        return chars / 4
    }

    /// Index of the most recent assistant message with tool interactions (protected from pruning).
    private func lastAssistantIndexWithTools(in msgs: [Message]) -> Int? {
        msgs.indices.last { msgs[$0].role == .assistant && !msgs[$0].toolInteractions.isEmpty }
    }

    /// Prune stored tool interactions from oldest turns to stay under context budget.
    /// The most recent turn with tools is always protected.
    /// Returns true if any pruning occurred (cache was broken).
    private func pruneToolInteractionsIfNeeded(
        calendarContext: String?,
        emailContext: String?,
        chunkSummaries: [ArchivedSummaryItem]
    ) -> Bool {
        let maxTokens = configuredMaxContextTokens()
        let targetTokens = configuredTargetContextTokens()
        let protectedIndex = lastAssistantIndexWithTools(in: messages)

        // Estimate full context: system prompt + all messages + all stored tool interactions
        var totalTokens = estimateSystemPromptTokens(
            calendarContext: calendarContext,
            emailContext: emailContext,
            chunkSummaries: chunkSummaries
        )
        var prunableToolTokens = 0
        for (i, message) in messages.enumerated() {
            totalTokens += message.content.count / 4 + 1
            totalTokens += message.imageFileNames.count * 50
            totalTokens += message.documentFileNames.count * 50
            let toolTokens = estimateToolInteractionTokens(message.toolInteractions)
            totalTokens += toolTokens
            if i != protectedIndex && message.role == .assistant && !message.toolInteractions.isEmpty {
                prunableToolTokens += toolTokens
            }
        }

        guard totalTokens > maxTokens else {
            print("[ConversationManager] Context budget OK: ~\(totalTokens) tokens <= \(maxTokens)")
            return false
        }

        // Skip if the only tool tokens are on the protected (most recent) turn
        guard prunableToolTokens > 0 else {
            print("[ConversationManager] Context budget exceeded (~\(totalTokens) > \(maxTokens)) but only the latest turn has tools — skipping prune")
            return false
        }

        print("[ConversationManager] Context budget exceeded: ~\(totalTokens) tokens > \(maxTokens). Pruning tool interactions to ~\(targetTokens)...")

        var prunedCount = 0
        for i in 0..<messages.count {
            guard totalTokens > targetTokens else { break }
            guard i != protectedIndex else { continue }
            guard messages[i].role == .assistant && !messages[i].toolInteractions.isEmpty else { continue }

            let savedTokens = estimateToolInteractionTokens(messages[i].toolInteractions)
            messages[i].toolInteractions = []
            totalTokens -= savedTokens
            prunedCount += 1
        }

        if prunedCount > 0 {
            pruneOldCompactToolLogs()
            saveConversation()
            print("[ConversationManager] Pruned tool interactions from \(prunedCount) turn(s). New estimate: ~\(totalTokens) tokens")
        }

        return prunedCount > 0
    }

    /// Mid-loop variant: prunes stored tool interactions from historical turns when the
    /// current turn's growing context would exceed the budget. Only touches historical
    /// messages (messagesForLLM), never the current turn's in-memory toolInteractions.
    /// The most recent historical turn with tools is always protected.
    private func pruneStoredToolInteractionsMidLoop(
        messagesForLLM: inout [Message],
        currentTurnInteractions: [ToolInteraction],
        calendarContext: String?,
        emailContext: String?,
        chunkSummaries: [ArchivedSummaryItem]
    ) -> Bool {
        let maxTokens = configuredMaxContextTokens()
        let targetTokens = configuredTargetContextTokens()
        let protectedIndex = lastAssistantIndexWithTools(in: messagesForLLM)

        var totalTokens = estimateSystemPromptTokens(
            calendarContext: calendarContext,
            emailContext: emailContext,
            chunkSummaries: chunkSummaries
        )
        var prunableToolTokens = 0
        for (i, message) in messagesForLLM.enumerated() {
            totalTokens += message.content.count / 4 + 1
            totalTokens += message.imageFileNames.count * 50
            totalTokens += message.documentFileNames.count * 50
            let toolTokens = estimateToolInteractionTokens(message.toolInteractions)
            totalTokens += toolTokens
            if i != protectedIndex && message.role == .assistant && !message.toolInteractions.isEmpty {
                prunableToolTokens += toolTokens
            }
        }
        totalTokens += estimateToolInteractionTokens(currentTurnInteractions)

        guard totalTokens > maxTokens, prunableToolTokens > 0 else { return false }

        print("[ConversationManager] Mid-loop context exceeded: ~\(totalTokens) > \(maxTokens). Pruning stored tool interactions...")

        var prunedCount = 0
        for i in 0..<messagesForLLM.count {
            guard totalTokens > targetTokens else { break }
            guard i != protectedIndex else { continue }
            guard messagesForLLM[i].role == .assistant && !messagesForLLM[i].toolInteractions.isEmpty else { continue }

            let savedTokens = estimateToolInteractionTokens(messagesForLLM[i].toolInteractions)
            messagesForLLM[i].toolInteractions = []
            totalTokens -= savedTokens
            prunedCount += 1
        }

        if prunedCount > 0 {
            // Persist to self.messages (indices correspond since no mutations during the loop)
            for i in 0..<min(messagesForLLM.count, messages.count) {
                if messagesForLLM[i].id == messages[i].id
                    && messagesForLLM[i].toolInteractions.isEmpty
                    && !messages[i].toolInteractions.isEmpty {
                    messages[i].toolInteractions = []
                }
            }
            pruneOldCompactToolLogs()
            // Also sync log pruning to messagesForLLM
            for i in 0..<min(messagesForLLM.count, messages.count) {
                if messagesForLLM[i].id == messages[i].id {
                    messagesForLLM[i].compactToolLog = messages[i].compactToolLog
                }
            }
            saveConversation()
            print("[ConversationManager] Mid-loop pruned \(prunedCount) turn(s). New estimate: ~\(totalTokens) tokens")
        }

        return prunedCount > 0
    }

    /// Keep at most 5 active compact tool logs (messages where interactions were pruned but log remains).
    /// Clears the oldest logs beyond the limit.
    private func pruneOldCompactToolLogs() {
        let maxRetainedCompactLogs = 5
        let activeLogIndices = messages.indices.filter {
            messages[$0].compactToolLog != nil && messages[$0].toolInteractions.isEmpty
        }
        let excessCount = activeLogIndices.count - maxRetainedCompactLogs
        guard excessCount > 0 else { return }

        for i in activeLogIndices.prefix(excessCount) {
            messages[i].compactToolLog = nil
        }
        print("[ConversationManager] Cleared \(excessCount) old compact tool log(s), keeping \(maxRetainedCompactLogs)")
    }

    // MARK: - System Prompt Cache Epoch

    /// Returns a frozen timestamp for the system prompt. Only refreshes on prune events
    /// or when the date changes (to keep "today" accurate).
    private func currentSystemPromptTimestamp() -> Date {
        if let stored = UserDefaults.standard.object(forKey: systemPromptTimestampKey) as? Date {
            if Calendar.current.isDateInToday(stored) {
                return stored
            }
        }
        let now = Date()
        UserDefaults.standard.set(now, forKey: systemPromptTimestampKey)
        return now
    }

    /// Force-refresh the system prompt timestamp (called when cache is already broken by pruning)
    private func refreshSystemPromptTimestamp() {
        UserDefaults.standard.set(Date(), forKey: systemPromptTimestampKey)
    }

    private func formatUSD(_ value: Double) -> String {
        var formatted = String(format: "%.6f", value)
        while formatted.contains(".") && formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." {
            formatted.removeLast()
        }
        return formatted
    }
    
    private func extractAccessedProjects(from interactions: [ToolInteraction]) -> [String] {
        var projectIds = Set<String>()
        let projectTools = Set(["manage_projects", "browse_project", "read_project_file", "add_project_files", "view_project_history", "view_project_deployment_history", "run_claude_code", "send_project_result"])
        
        for interaction in interactions {
            for call in interaction.assistantMessage.toolCalls {
                guard projectTools.contains(call.function.name) else { continue }
                
                if let data = call.function.arguments.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let projectId = json["project_id"] as? String {
                        projectIds.insert(projectId)
                    } else if let projectName = json["project_name"] as? String {
                        let isCreateProjectCall = call.function.name == "create_project"
                        let isManageProjectsCreate = call.function.name == "manage_projects"
                            && ((json["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "create")

                        guard isCreateProjectCall || isManageProjectsCreate else { continue }

                        // For project creation, the ID is derived from the name
                        let generatedId = projectName
                            .lowercased()
                            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                        projectIds.insert(generatedId)
                    }
                }
            }
        }
        return Array(projectIds).sorted()
    }
    
    private func blockedToolResult(for call: ToolCall, deploymentToolsUnlockedForTurn: Bool) -> ToolResultMessage {
        let gatedToolNames = Set(AvailableTools.gatedProjectDeploymentTools.map { $0.function.name })
        let requestedTool = call.function.name
        
        let errorMessage: String
        if gatedToolNames.contains(requestedTool) && !deploymentToolsUnlockedForTurn {
            errorMessage = "Tool '\(requestedTool)' is currently gated. Call show_project_deployment_tools first to unlock deployment/database tools for this turn."
        } else if requestedTool == "show_project_deployment_tools" && deploymentToolsUnlockedForTurn {
            errorMessage = "Tool 'show_project_deployment_tools' was already used in this turn and is no longer available. Continue with the unlocked deployment/database tools."
        } else {
            errorMessage = "Tool '\(requestedTool)' is not available in this turn."
        }
        
        let escapedError = errorMessage
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return ToolResultMessage(toolCallId: call.id, content: #"{"error":"\#(escapedError)"}"#)
    }

    private func blockedToolResult(for call: ToolCall, errorMessage: String) -> ToolResultMessage {
        let escapedError = errorMessage
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return ToolResultMessage(toolCallId: call.id, content: #"{"error":"\#(escapedError)"}"#)
    }

    private func partitionToolCallsForExecution(
        _ calls: [ToolCall],
        allowedToolNames: Set<String>,
        deploymentToolsUnlockedForTurn: Bool,
        priorInteractions: [ToolInteraction],
        historicalMessages: [Message] = []
    ) -> (executableCalls: [ToolCall], blockedResults: [ToolResultMessage]) {
        let turnState = buildProjectToolTurnState(from: priorInteractions, historicalMessages: historicalMessages)
        let deploymentToolsRequiringHistory = Set([
            "deploy_project_to_vercel",
            "provision_project_database",
            "push_project_database_schema",
            "sync_project_database_env_to_vercel",
            "generate_project_mcp_config"
        ])
        var executableCalls: [ToolCall] = []
        var blockedResults: [ToolResultMessage] = []
        var historyRequestedThisRound = Set<String>()
        var deploymentHistoryRequestedThisRound = Set<String>()

        for call in calls {
            guard allowedToolNames.contains(call.function.name) else {
                blockedResults.append(
                    blockedToolResult(for: call, deploymentToolsUnlockedForTurn: deploymentToolsUnlockedForTurn)
                )
                continue
            }

            switch call.function.name {
            case "view_project_history":
                guard let projectID = projectIDFromArguments(of: call) else {
                    executableCalls.append(call)
                    continue
                }

                if turnState.projectsWithSuccessfulHistory.contains(projectID) {
                    blockedResults.append(
                        blockedToolResult(
                            for: call,
                            errorMessage: "view_project_history was already loaded successfully for project '\(projectID)' earlier in this turn. Reuse that context instead of calling it again."
                        )
                    )
                } else if historyRequestedThisRound.contains(projectID) {
                    blockedResults.append(
                        blockedToolResult(
                            for: call,
                            errorMessage: "view_project_history was already requested for project '\(projectID)' in this round. Call it at most once per turn per project unless a prior history load failed."
                        )
                    )
                } else {
                    historyRequestedThisRound.insert(projectID)
                    executableCalls.append(call)
                }

            case "view_project_deployment_history":
                guard let projectID = projectIDFromArguments(of: call) else {
                    executableCalls.append(call)
                    continue
                }

                if turnState.projectsWithSuccessfulDeploymentHistory.contains(projectID) {
                    blockedResults.append(
                        blockedToolResult(
                            for: call,
                            errorMessage: "view_project_deployment_history was already loaded successfully for project '\(projectID)' earlier in this turn. Reuse that context instead of calling it again."
                        )
                    )
                } else if deploymentHistoryRequestedThisRound.contains(projectID) {
                    blockedResults.append(
                        blockedToolResult(
                            for: call,
                            errorMessage: "view_project_deployment_history was already requested for project '\(projectID)' in this round. Call it at most once per turn per project unless a prior history load failed."
                        )
                    )
                } else {
                    deploymentHistoryRequestedThisRound.insert(projectID)
                    executableCalls.append(call)
                }

            case "run_claude_code":
                guard let projectID = projectIDFromArguments(of: call) else {
                    executableCalls.append(call)
                    continue
                }

                if turnState.createdProjectIDs.contains(projectID) || turnState.projectsWithSuccessfulHistory.contains(projectID) {
                    executableCalls.append(call)
                } else {
                    blockedResults.append(
                        blockedToolResult(
                            for: call,
                            errorMessage: "Before reusing existing project '\(projectID)', call view_project_history for that same project_id in an earlier tool round of this turn. After that result is returned, call run_claude_code."
                        )
                    )
                }

            case let toolName where deploymentToolsRequiringHistory.contains(toolName):
                guard let projectID = projectIDFromArguments(of: call) else {
                    executableCalls.append(call)
                    continue
                }

                if turnState.createdProjectIDs.contains(projectID) || turnState.projectsWithSuccessfulDeploymentHistory.contains(projectID) {
                    executableCalls.append(call)
                } else {
                    blockedResults.append(
                        blockedToolResult(
                            for: call,
                            errorMessage: "Before using \(toolName) on existing project '\(projectID)', call view_project_deployment_history for that same project_id in an earlier tool round of this turn. After that result is returned, retry the deployment/database tool."
                        )
                    )
                }

            default:
                executableCalls.append(call)
            }
        }

        return (executableCalls, blockedResults)
    }

    private func buildProjectToolTurnState(from interactions: [ToolInteraction], historicalMessages: [Message] = []) -> ProjectToolTurnState {
        var state = ProjectToolTurnState()

        // Scan stored tool interactions from previous turns (visible to the model via persistence)
        for message in historicalMessages where message.role == .assistant {
            for interaction in message.toolInteractions {
                processInteractionForTurnState(interaction, state: &state)
            }
        }

        // Scan current turn's interactions
        for interaction in interactions {
            processInteractionForTurnState(interaction, state: &state)
        }

        return state
    }

    private func processInteractionForTurnState(_ interaction: ToolInteraction, state: inout ProjectToolTurnState) {
        var resultByCallID: [String: ToolResultMessage] = [:]
        for result in interaction.results {
            resultByCallID[result.toolCallId] = result
        }

        for call in interaction.assistantMessage.toolCalls {
            guard let result = resultByCallID[call.id],
                  let resultDictionary = parseJSONDictionary(from: result.content) else {
                continue
            }

            switch call.function.name {
            case "create_project":
                guard (resultDictionary["success"] as? Bool) == true,
                      let projectID = resultDictionary["project_id"] as? String,
                      !projectID.isEmpty else {
                    continue
                }
                state.createdProjectIDs.insert(projectID)

            case "manage_projects":
                guard manageProjectsAction(from: call) == "create",
                      (resultDictionary["success"] as? Bool) == true,
                      let projectID = resultDictionary["project_id"] as? String,
                      !projectID.isEmpty else {
                    continue
                }
                state.createdProjectIDs.insert(projectID)

            case "view_project_history":
                guard (resultDictionary["success"] as? Bool) == true else {
                    continue
                }

                if let projectID = resultDictionary["projectId"] as? String, !projectID.isEmpty {
                    state.projectsWithSuccessfulHistory.insert(projectID)
                } else if let projectID = resultDictionary["project_id"] as? String, !projectID.isEmpty {
                    state.projectsWithSuccessfulHistory.insert(projectID)
                } else if let projectID = projectIDFromArguments(of: call) {
                    state.projectsWithSuccessfulHistory.insert(projectID)
                }

            case "view_project_deployment_history":
                guard (resultDictionary["success"] as? Bool) == true else {
                    continue
                }

                if let projectID = resultDictionary["projectId"] as? String, !projectID.isEmpty {
                    state.projectsWithSuccessfulDeploymentHistory.insert(projectID)
                } else if let projectID = resultDictionary["project_id"] as? String, !projectID.isEmpty {
                    state.projectsWithSuccessfulDeploymentHistory.insert(projectID)
                } else if let projectID = projectIDFromArguments(of: call) {
                    state.projectsWithSuccessfulDeploymentHistory.insert(projectID)
                }

            default:
                continue
            }
        }
    }

    private func projectIDFromArguments(of call: ToolCall) -> String? {
        guard let data = call.function.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projectID = object["project_id"] as? String else {
            return nil
        }

        let normalized = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func manageProjectsAction(from call: ToolCall) -> String? {
        guard call.function.name == "manage_projects",
              let data = call.function.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String else {
            return nil
        }

        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
    
    /// Get appropriate progress message for tool calls
    private func getProgressMessage(for calls: [ToolCall]) -> String {
        let toolNames = Set(calls.map { $0.function.name })
        let hasWebSearchOp = toolNames.contains("web_search") || toolNames.contains("deep_research")
        let hasDeepResearchOp = toolNames.contains("deep_research")
        
        // Check for calendar operations
        let hasCalendarOp = toolNames.contains("manage_calendar")
        let hasReminderOp = toolNames.contains("manage_reminders")
        let hasContactOp = toolNames.contains("manage_contacts")
        
        // Check for email operations
        let hasEmailOp = toolNames.contains("read_emails")
            || toolNames.contains("search_emails")
            || toolNames.contains("send_email")
            || toolNames.contains("reply_email")
            || toolNames.contains("forward_email")
            || toolNames.contains("gmailreader")
            || toolNames.contains("gmailcomposer")
        
        if hasDeepResearchOp && hasReminderOp {
            return "🧠🔍 Deep researching and managing reminders..."
        } else if hasDeepResearchOp && hasCalendarOp {
            return "🧠🔍📅 Deep researching and managing calendar..."
        } else if hasDeepResearchOp {
            return "🧠🔍 Running deep research..."
        } else if hasWebSearchOp && hasReminderOp {
            return "🔍 Searching the web and managing reminders..."
        } else if hasWebSearchOp && hasCalendarOp {
            return "🔍📅 Searching the web and managing calendar..."
        } else if hasWebSearchOp {
            return "🔍 Searching the web..."
        } else if toolNames.contains("show_project_deployment_tools") {
            return "🧰 Enabling deployment and database tools for this turn..."
        } else if toolNames.contains("view_project_deployment_history") {
            return "🧰 Reviewing deployment history..."
        } else if toolNames.contains("provision_project_database") {
            return "🗄️ Provisioning project database..."
        } else if toolNames.contains("push_project_database_schema") {
            return "🧱 Applying project database schema..."
        } else if toolNames.contains("sync_project_database_env_to_vercel") {
            return "🔐 Syncing database environment variables to Vercel..."
        } else if toolNames.contains("generate_project_mcp_config") {
            return "🧩 Generating MCP configuration..."
        } else if toolNames.contains("run_claude_code") {
            let provider = (KeychainHelper.load(key: KeychainHelper.codeCLIProviderKey) ?? KeychainHelper.defaultCodeCLIProvider)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch provider {
            case "gemini":
                return "🤖 Running Gemini CLI..."
            case "codex":
                return "🤖 Running Codex CLI..."
            default:
                return "🤖 Running Claude Code..."
            }
        } else if toolNames.contains("manage_projects") || toolNames.contains("browse_project") || toolNames.contains("read_project_file") || toolNames.contains("add_project_files") {
            return "📁 Managing project workspace..."
        } else if toolNames.contains("send_project_result") {
            return "📤 Sending project result..."
        } else if toolNames.contains("deploy_project_to_vercel") {
            return "🚀 Deploying project to Vercel..."
        } else if hasReminderOp {
            return "⏰ Managing reminders..."
        } else if hasCalendarOp {
            return "📅 Managing calendar..."
        } else if hasContactOp {
            return "👥 Managing contacts..."
        } else if toolNames.contains("search_emails") {
            return "🔎 Searching emails..."
        } else if toolNames.contains("read_emails") {
            return "📧 Reading emails..."
        } else if toolNames.contains("send_email") {
            return "📤 Sending email..."
        } else if toolNames.contains("reply_email") {
            return "↩️ Replying to email..."
        } else if toolNames.contains("forward_email") {
            return "📨 Forwarding email..."
        } else if toolNames.contains("gmailreader") {
            return "📧 Reading Gmail..."
        } else if toolNames.contains("gmailcomposer") {
            return "📤 Composing Gmail..."
        } else if toolNames.contains("shortcuts") {
            return "⌘ Running shortcuts..."
        } else if hasEmailOp {
            return "📧 Managing email..."
        } else if toolNames.contains("read_document") {
            return "📄 Opening document..."
        } else {
            return "🔧 Processing..."
        }
    }
    
    /// Build a compact per-step tool log to persist in conversation memory
    /// right before the final assistant response.
    private func buildCompactToolExecutionLog(from interactions: [ToolInteraction]) -> String? {
        guard !interactions.isEmpty else { return nil }
        
        var lines: [String] = [toolRunLogPrefix]
        var stepIndex = 1
        
        for interaction in interactions {
            var resultByCallId: [String: ToolResultMessage] = [:]
            for result in interaction.results {
                resultByCallId[result.toolCallId] = result
            }
            
            for call in interaction.assistantMessage.toolCalls {
                let outcome = summarizeToolOutcome(resultByCallId[call.id])
                lines.append("\(stepIndex). \(call.function.name): \(outcome)")
                stepIndex += 1
            }
        }
        
        guard stepIndex > 1 else { return nil }
        return lines.joined(separator: "\n")
    }
    
    private func summarizeToolOutcome(_ result: ToolResultMessage?) -> String {
        guard let result else { return "no-result" }
        
        let fileSuffix = result.fileAttachments.isEmpty
            ? ""
            : " (+\(result.fileAttachments.count) file\(result.fileAttachments.count == 1 ? "" : "s"))"
        
        if let dict = parseJSONDictionary(from: result.content) {
            if let error = dict["error"] as? String, !error.isEmpty {
                return "error - \(compact(error, maxLength: 90))\(fileSuffix)"
            }
            
            if let message = dict["message"] as? String, !message.isEmpty {
                return "ok - \(compact(message, maxLength: 90))\(fileSuffix)"
            }
            
            if let summary = dict["summary"] as? String, !summary.isEmpty {
                return "ok - \(compact(summary, maxLength: 90))\(fileSuffix)"
            }
            
            if let downloadedCount = dict["downloadedCount"] as? Int {
                return "ok - downloaded \(downloadedCount)\(fileSuffix)"
            }
            
            if let count = dict["count"] as? Int {
                return "ok - count \(count)\(fileSuffix)"
            }
            
            if let eventCount = dict["eventCount"] as? Int {
                return "ok - events \(eventCount)\(fileSuffix)"
            }
            
            if let success = dict["success"] as? Bool {
                return (success ? "ok" : "failed") + fileSuffix
            }
            
            return "ok\(fileSuffix)"
        }
        
        let fallback = compact(result.content, maxLength: 90)
        return (fallback.isEmpty ? "ok" : fallback) + fileSuffix
    }
    
    private func parseJSONDictionary(from content: String) -> [String: Any]? {
        guard let jsonContent = extractJSONObjectString(from: content),
              let data = jsonContent.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    private func extractJSONObjectString(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startIndex = trimmed.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var isEscaping = false

        for index in trimmed[startIndex...].indices {
            let character = trimmed[index]

            if inString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(trimmed[startIndex...index])
                }
            default:
                continue
            }
        }

        return nil
    }
    
    private func compact(_ text: String, maxLength: Int) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard flattened.count > maxLength else { return flattened }
        return String(flattened.prefix(maxLength)) + "..."
    }
    
    private func isToolRunLogMessage(_ message: Message) -> Bool {
        message.role == .assistant && message.content.hasPrefix(toolRunLogPrefix)
    }
    
    /// Keep only the most recent N compact tool-log messages to avoid context bloat.
    @discardableResult
    private func pruneOldToolLogMessages() -> Int {
        let logIndices = messages.indices.filter { isToolRunLogMessage(messages[$0]) }
        let excessCount = logIndices.count - maxRetainedToolRunLogs
        guard excessCount > 0 else { return 0 }
        
        let indicesToRemove = logIndices.prefix(excessCount).sorted(by: >)
        for index in indicesToRemove {
            messages.remove(at: index)
        }
        
        return excessCount
    }
    
    // MARK: - Reminder Processing
    
    private func checkDueReminders() async {
        // Clear any previous error when checking reminders
        error = nil
        
        // Don't run reminder workflows while a user-triggered run is active
        guard activeRunId == nil else { return }
        
        let dueReminders = await ReminderService.shared.getDueReminders()
        
        guard !dueReminders.isEmpty else { return }
        
        for reminder in dueReminders {
            // Mark as triggered FIRST to prevent race conditions with next poll iteration
            await ReminderService.shared.markTriggered(id: reminder.id)
            
            // If this is a recurring reminder, schedule the next occurrence
            if reminder.recurrence != nil {
                if let nextReminder = await ReminderService.shared.rescheduleRecurring(id: reminder.id) {
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateStyle = .medium
                    dateFormatter.timeStyle = .short
                    print("[ConversationManager] Recurring reminder rescheduled for: \(dateFormatter.string(from: nextReminder.triggerDate))")
                }
            }
            
            print("[ConversationManager] Processing due reminder: \(reminder.id)")
            statusMessage = "Processing reminder..."
            
            // Notify user that a reminder is being processed
            if let chatId = pairedChatId {
                try? await telegramService.sendMessage(chatId: chatId, text: "⏰ Reminder triggered!")
            }
            
            // Format the reminder as a user message so the LLM can respond to it
            let reminderPrompt = """
            [SCHEDULED REMINDER - This is a message you wrote to yourself earlier]
            
            \(reminder.prompt)
            
            [END OF REMINDER - Please act on these instructions now]
            """
            
            // Add the reminder as a user message
            let userMessage = Message(role: .user, content: reminderPrompt)
            messages.append(userMessage)
            saveConversation()
            
            // Generate LLM response with tools available
            do {
                let turnStartDate = Date()
                let response = try await generateResponseWithTools(currentUserMessageId: userMessage.id, turnStartDate: turnStartDate)
                
                if let toolLog = response.compactToolLog, !toolLog.isEmpty {
                    messages.append(Message(role: .assistant, content: toolLog))
                    pruneOldToolLogMessages()
                }
                
                // Add assistant message (guard against empty response)
                let finalResponseRaw = response.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "I completed the reminder actions."
                    : response.finalText
                let finalResponse = capAssistantMessageForHistoryAndTelegram(finalResponseRaw)
                let downloadedFilenames = ToolExecutor.getPendingDownloadedFilenames()
                let assistantMessage = Message(
                    role: .assistant, 
                    content: finalResponse, 
                    downloadedDocumentFileNames: downloadedFilenames,
                    accessedProjectIds: response.accessedProjects ?? []
                )
                messages.append(assistantMessage)
                saveConversation()
                
                // Send reply via Telegram
                if let chatId = pairedChatId {
                    try await telegramService.sendMessage(chatId: chatId, text: finalResponse)
                }
                
                print("[ConversationManager] Reminder \(reminder.id) processed successfully")
            } catch {
                self.error = "Failed to process reminder: \(error.localizedDescription)"
                print("[ConversationManager] Failed to process reminder: \(error)")
            }
        }
        
        statusMessage = "Listening... (Last check: \(formattedTime()))"
    }
    
    // MARK: - Smart Email Notifications
    
    /// Process new emails: use Gemini with full context to decide if notification-worthy
    /// and generate a personalized notification message.
    /// Runs in a detached context to avoid blocking user interactions.
    private func processNewEmails(_ emails: [EmailMessage]) async {
        guard pairedChatId != nil, !emails.isEmpty else { return }
        
        print("[ConversationManager] Processing \(emails.count) new email(s) for notification")
        
        // Build full email details (not just summaries)
        var emailDetails: [String] = []
        for email in emails {
            var detail = """
            ---
            From: \(email.from)
            Subject: \(email.subject)
            Date: \(email.date)
            UID: \(email.id)
            """
            if !email.bodyPreview.isEmpty {
                detail += "\nBody:\n\(email.bodyPreview)"
            }
            if !email.attachments.isEmpty {
                let attachNames = email.attachments.map { "\($0.filename) (\($0.mimeType))" }.joined(separator: ", ")
                detail += "\nAttachments: \(attachNames)"
            }
            emailDetails.append(detail)
        }
        
        // Wait for any active execution to finish so we don't drop the email event or run in parallel
        while activeRunId != nil || activeProcessingTask != nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        
        let emailContent = """
        [SYSTEM: NEW EMAILS ARRIVED]
        The following new emails have just arrived in your inbox. Please tell the user about them naturally. 
        If they seem unimportant (spam, promotions, newsletters), you can briefly mention them or skip detailing them, but you must still reply.
        You have access to your full toolset, so you can perform actions like replying to the emails directly if appropriate.
        
        New emails:
        \(emailDetails.joined(separator: "\n"))
        """
        
        let userMessage = Message(role: .user, content: emailContent)
        messages.append(userMessage)
        
        statusMessage = "Processing new emails..."
        startActiveProcessing(
            for: userMessage,
            postRunUserMessageContent: compactedEmailNotificationContent(from: emails)
        )
    }
    
    /// Process new Gmail emails (Gmail API version of processNewEmails)
    private func processNewGmailEmails(_ emails: [GmailMessage]) async {
        guard pairedChatId != nil, !emails.isEmpty else { return }
        
        print("[ConversationManager] Processing \(emails.count) new Gmail email(s) for notification")
        
        // Build full email details
        var emailDetails: [String] = []
        for email in emails {
            let from = email.getHeader("From") ?? "Unknown"
            let subject = email.getHeader("Subject") ?? "(No subject)"
            let date = email.getHeader("Date") ?? ""
            let body = email.getPlainTextBody()
            
            var detail = """
            ---
            From: \(from)
            Subject: \(subject)
            Date: \(date)
            ID: \(email.id)
            """
            if !body.isEmpty {
                detail += "\nBody:\n\(body)"
            }
            let attachments = email.payload?.getAttachmentParts() ?? []
            if !attachments.isEmpty {
                let attachNames = attachments.compactMap { "\($0.filename ?? "file") (\($0.mimeType ?? "unknown"))" }.joined(separator: ", ")
                detail += "\nAttachments: \(attachNames)"
            }
            emailDetails.append(detail)
        }
        
        // Wait for any active execution to finish so we don't drop the email event or run in parallel
        while activeRunId != nil || activeProcessingTask != nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        
        let emailContent = """
        [SYSTEM: NEW EMAILS ARRIVED]
        The following new emails have just arrived in your inbox. Please tell the user about them naturally. 
        If they seem unimportant (spam, promotions, newsletters), you can briefly mention them or skip detailing them, but you must still reply.
        You have access to your full toolset, so you can perform actions like replying to the emails directly if appropriate.
        
        New emails:
        \(emailDetails.joined(separator: "\n"))
        """
        
        let userMessage = Message(role: .user, content: emailContent)
        messages.append(userMessage)
        
        statusMessage = "Processing new Gmail emails..."
        startActiveProcessing(
            for: userMessage,
            postRunUserMessageContent: compactedGmailNotificationContent(from: emails)
        )
    }

    private func compactedEmailNotificationContent(from emails: [EmailMessage]) -> String {
        var lines: [String] = [
            "[SYSTEM: NEW EMAILS ARRIVED - CONTENT PURGED]",
            "Body removed to save context.",
            "Before acting/replying: fetch full text with email/Gmail tools first; never act blindly.",
            "",
            "Metadata:"
        ]
        
        for email in emails {
            lines.append("---")
            lines.append("From: \(email.from)")
            lines.append("Subject: \(email.subject)")
            lines.append("Date: \(email.date)")
            lines.append("UID: \(email.id)")
            if !email.messageId.isEmpty {
                lines.append("Message-ID: \(email.messageId)")
            }
            if let inReplyTo = email.inReplyTo, !inReplyTo.isEmpty {
                lines.append("In-Reply-To: \(inReplyTo)")
            }
            if let references = email.references, !references.isEmpty {
                lines.append("References: \(references)")
            }
            if !email.attachments.isEmpty {
                let names = email.attachments.map { "\($0.filename) (\($0.mimeType))" }.joined(separator: ", ")
                lines.append("Attachments: \(names)")
            }
        }
        
        return lines.joined(separator: "\n")
    }

    private func compactedGmailNotificationContent(from emails: [GmailMessage]) -> String {
        var lines: [String] = [
            "[SYSTEM: NEW EMAILS ARRIVED - CONTENT PURGED]",
            "Body removed to save context.",
            "Before acting/replying: fetch full text with Gmail tools first; never act blindly.",
            "",
            "Metadata:"
        ]
        
        for email in emails {
            let from = email.getHeader("From") ?? "Unknown"
            let subject = email.getHeader("Subject") ?? "(No subject)"
            let date = email.getHeader("Date") ?? ""
            lines.append("---")
            lines.append("From: \(from)")
            lines.append("Subject: \(subject)")
            lines.append("Date: \(date)")
            lines.append("Message ID: \(email.id)")
            lines.append("Thread ID: \(email.threadId)")
            let attachments = email.payload?.getAttachmentParts() ?? []
            if !attachments.isEmpty {
                let names = attachments.compactMap { "\($0.filename ?? "file") (\($0.mimeType ?? "unknown"))" }.joined(separator: ", ")
                lines.append("Attachments: \(names)")
            }
        }
        
        return lines.joined(separator: "\n")
    }

    @discardableResult
    private func replaceMessageContent(for messageId: UUID, with content: String) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return false }
        let existing = messages[index]
        guard existing.content != content else { return false }
        
        messages[index] = Message(
            id: existing.id,
            role: existing.role,
            content: content,
            timestamp: existing.timestamp,
            imageFileNames: existing.imageFileNames,
            documentFileNames: existing.documentFileNames,
            imageFileSizes: existing.imageFileSizes,
            documentFileSizes: existing.documentFileSizes,
            referencedImageFileNames: existing.referencedImageFileNames,
            referencedDocumentFileNames: existing.referencedDocumentFileNames,
            referencedDocumentFileSizes: existing.referencedDocumentFileSizes,
            downloadedDocumentFileNames: existing.downloadedDocumentFileNames,
            accessedProjectIds: existing.accessedProjectIds
        )
        return true
    }
    
    // MARK: - Persistence
    
    private func loadConversation() {
        guard FileManager.default.fileExists(atPath: conversationFileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: conversationFileURL)
            messages = try JSONDecoder().decode([Message].self, from: data)
            // Cleanup old compact tool logs from previous runs to keep context lean.
            if pruneOldToolLogMessages() > 0 {
                saveConversation()
            }
        } catch {
            print("Failed to load conversation: \(error)")
        }
    }
    
    private func saveConversation() {
        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: conversationFileURL)
        } catch {
            print("Failed to save conversation: \(error)")
        }
    }
    
    func clearConversation() {
        messages = []
        saveConversation()
        
        // Also clear images
        try? FileManager.default.removeItem(at: imagesDirectory)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }
    
    /// Delete all memory: conversation, chunks, summaries, user context, reminders
    /// Keeps: Calendar and Contacts
    func deleteAllMemory() async {
        // 1. Clear conversation and images
        clearConversation()
        
        // 2. Clear all archived chunks
        await archiveService.clearAllArchives()
        
        // 3. Clear all reminders
        await ReminderService.shared.clearAllReminders()
        
        // 4. Clear user context from Keychain
        try? KeychainHelper.delete(key: KeychainHelper.userContextKey)
        try? KeychainHelper.delete(key: KeychainHelper.structuredUserContextKey)
        
        // 5. Clear documents directory
        try? FileManager.default.removeItem(at: documentsDirectory)
        try? FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        
        // 6. Clear file descriptions
        await FileDescriptionService.shared.clearAll()
        
        print("[ConversationManager] All memory deleted")
    }
    
    /// Reload all data from disk after Mind restore
    /// This refreshes the conversation and archive service to pick up restored data
    func reloadAfterMindRestore() async {
        loadConversation()
        await archiveService.reloadFromDisk()
        print("[ConversationManager] Reloaded data after Mind restore")
    }
    
    // MARK: - Helpers
    
    private func formattedTime() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }

    private func capAssistantMessageForHistoryAndTelegram(_ text: String) -> String {
        let utf16Count = text.utf16.count
        guard utf16Count > maxAssistantMessageChars else { return text }
        // Truncate by UTF-16 code units (Telegram uses UTF-16 counting for its 4096 limit).
        // Walk the string keeping only characters whose cumulative UTF-16 length fits.
        var used = 0
        var endIndex = text.startIndex
        for idx in text.indices {
            let charUTF16Len = text[idx].utf16.count
            if used + charUTF16Len > maxAssistantMessageChars { break }
            used += charUTF16Len
            endIndex = text.index(after: idx)
        }
        let capped = String(text[text.startIndex..<endIndex])
        print("[ConversationManager] Assistant message capped to first \(maxAssistantMessageChars) UTF-16 units (original: \(utf16Count))")
        return capped
    }
    
    // MARK: - Image Access (for UI)
    
    func imageURL(for message: Message) -> URL? {
        guard let fileName = message.imageFileName else { return nil }
        let url = imagesDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    /// Returns all image URLs for a message (primary attachments)
    func imageURLs(for message: Message) -> [URL] {
        message.imageFileNames.compactMap { fileName in
            let url = imagesDirectory.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
    
    /// Returns all referenced image URLs for a message (from replied-to messages)
    func referencedImageURLs(for message: Message) -> [URL] {
        message.referencedImageFileNames.compactMap { fileName in
            let url = imagesDirectory.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
    
    /// Returns the URL for a document file
    func documentURL(fileName: String) -> URL? {
        let url = documentsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    // MARK: - Context for Settings Structuring
    
    /// Get conversation context for the "Process & Save" feature in Settings.
    /// Returns recent messages and chunk summaries so Gemini has full awareness.
    func getContextForStructuring() async -> (recentMessages: [Message], chunkSummaries: [ArchivedSummaryItem]) {
        let chunkSummaries = await archiveService.getPromptSummaryItems(recentConsolidatedCount: 5)
        // Return last 20 messages for recent context
        let recentMessages = Array(messages.suffix(20))
        return (recentMessages, chunkSummaries)
    }
    
    /// Load the full archived text for a specific chunk.
    func getArchivedChunkContent(chunkId: UUID) async throws -> String {
        try await archiveService.getChunkContent(chunkId: chunkId)
    }
    
    // MARK: - Summarization Context Builder
    
    /// Build full context for summarization so the LLM can properly understand
    /// relationships, references, and meaning in the chunk being archived.
    /// Note: Calendar is deliberately excluded - it contains future events not relevant to historical summarization.
    private func buildSummarizationContext(
        chunkSummaries: [ArchivedSummaryItem],
        currentMessages: [Message]
    ) -> ConversationArchiveService.SummarizationContext {
        // Get persona settings
        let personaContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey)
        let assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey)
        let userName = KeychainHelper.load(key: KeychainHelper.userNameKey)
        
        // Format previous summaries chronologically
        let previousSummaries = chunkSummaries.sorted { $0.startDate < $1.startDate }.map { $0.summary }
        
        // Format current conversation context (last ~10 messages of what's happening now)
        let recentMessages = currentMessages.suffix(10)
        let currentContext: String?
        if !recentMessages.isEmpty {
            currentContext = recentMessages.map { msg in
                let role = msg.role == .user ? "User" : "Assistant"
                return "[\(role)]: \(msg.content.prefix(500))"
            }.joined(separator: "\n")
        } else {
            currentContext = nil
        }
        
        return ConversationArchiveService.SummarizationContext(
            personaContext: personaContext,
            assistantName: assistantName,
            userName: userName,
            previousSummaries: previousSummaries,
            currentConversationContext: currentContext
        )
    }
    
    // MARK: - File Description Helpers
    
    /// Collect files from a message for description generation
    private func collectFilesForDescription(from message: Message) -> [(filename: String, data: Data, mimeType: String)] {
        var files: [(filename: String, data: Data, mimeType: String)] = []
        
        // Collect images
        for imageFileName in message.imageFileNames {
            let imageURL = imagesDirectory.appendingPathComponent(imageFileName)
            if let imageData = try? Data(contentsOf: imageURL) {
                let ext = imageURL.pathExtension.lowercased()
                let mimeType: String
                switch ext {
                case "png": mimeType = "image/png"
                case "gif": mimeType = "image/gif"
                case "webp": mimeType = "image/webp"
                case "heic": mimeType = "image/heic"
                default: mimeType = "image/jpeg"
                }
                files.append((filename: imageFileName, data: imageData, mimeType: mimeType))
            }
        }
        
        // Collect documents
        for documentFileName in message.documentFileNames {
            let documentURL = documentsDirectory.appendingPathComponent(documentFileName)
            if let documentData = try? Data(contentsOf: documentURL) {
                let ext = documentURL.pathExtension.lowercased()
                let mimeType: String
                switch ext {
                case "pdf": mimeType = "application/pdf"
                case "txt": mimeType = "text/plain"
                case "md": mimeType = "text/markdown"
                case "json": mimeType = "application/json"
                case "csv": mimeType = "text/csv"
                case "mp3": mimeType = "audio/mpeg"
                case "m4a": mimeType = "audio/mp4"
                case "wav": mimeType = "audio/wav"
                case "ogg", "oga": mimeType = "audio/ogg"
                case "aac": mimeType = "audio/aac"
                case "flac": mimeType = "audio/flac"
                case "jpg", "jpeg": mimeType = "image/jpeg"
                case "png": mimeType = "image/png"
                case "gif": mimeType = "image/gif"
                case "webp": mimeType = "image/webp"
                case "heic": mimeType = "image/heic"
                default: mimeType = "application/octet-stream"
                }
                files.append((filename: documentFileName, data: documentData, mimeType: mimeType))
            }
        }
        
        return files
    }
}
