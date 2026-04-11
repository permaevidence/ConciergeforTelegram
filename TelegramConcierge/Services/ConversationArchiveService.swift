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
    private let metaSummaryBatchSize = 5
    private let maxVisibleMetaSummaryCount = 10
    private let rollingMetaSummaryMinimumChunkCount = 2
    private let summaryTargetTokens = 1500
    private let minimumSummaryWordCount = 100
    private let summaryMaxCharacters = 10_000
    private let chunksToConsolidate = 4      // 4 × chunk_size = consolidatedChunkSize
    private let consolidationTriggerCount = 6 // Trigger at 6 temps, leaving 2 as buffer
    
    // Archive LLM config
    private var isLMStudio: Bool {
        LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey)) == .lmStudio
    }

    private var baseURL: URL {
        if isLMStudio {
            var base = KeychainHelper.load(key: KeychainHelper.lmStudioBaseURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if base.isEmpty { base = KeychainHelper.defaultLMStudioBaseURL }
            while base.hasSuffix("/") { base.removeLast() }
            if base.hasSuffix("/chat/completions"), let url = URL(string: base) {
                return url
            }
            if !base.hasSuffix("/v1") {
                base += "/v1"
            }
            return URL(string: base + "/chat/completions")!
        }
        return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    }

    private var model: String {
        if isLMStudio {
            return (KeychainHelper.load(key: KeychainHelper.lmStudioModelKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return KeychainHelper.load(key: KeychainHelper.openRouterModelKey) ?? "google/gemini-3-flash-preview"
    }
    private var apiKey: String = ""
    
    /// Returns the user-configured reasoning effort, defaulting to "high" on OpenRouter.
    private var reasoningEffort: String? {
        guard !isLMStudio else { return nil }
        guard let effort = KeychainHelper.load(key: KeychainHelper.openRouterReasoningEffortKey),
              !effort.isEmpty else {
            return "high"
        }
        return effort
    }
    
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

    private var pendingMetaIndexFileURL: URL {
        archiveFolder.appendingPathComponent("pending_meta_summaries.json")
    }
    
    private var chunkIndex: ChunkIndex = .empty()
    private var pendingIndex: PendingChunkIndex = .empty()
    private var pendingMetaIndex: PendingMetaSummaryIndex = .empty()
    
    // Cached live context for consolidation (updated when archiveMessages is called)
    private var cachedLiveContext: String?

    /// Optional callback for status notifications (e.g., sending Telegram messages)
    private var onStatusNotification: (@Sendable (String) -> Void)?

    func setStatusNotificationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onStatusNotification = handler
    }
    
    // MARK: - Initialization
    
    init() {
        loadIndex()
        loadPendingIndex()
        loadPendingMetaIndex()
    }
    
    /// Called on startup to resume any pending chunks from previous crash.
    /// Uses the provided summarization context so recovery summaries preserve continuity.
    func recoverPendingChunks(defaultContext: SummarizationContext = .empty) async {
        if !pendingIndex.pendingChunks.isEmpty {
            print("[ArchiveService] Found \(pendingIndex.pendingChunks.count) pending chunk(s) from previous session, recovering...")

            let personaContext = defaultContext.personaContext ?? KeychainHelper.load(key: KeychainHelper.structuredUserContextKey)
            let assistantName = defaultContext.assistantName ?? KeychainHelper.load(key: KeychainHelper.assistantNameKey)
            let userName = defaultContext.userName ?? KeychainHelper.load(key: KeychainHelper.userNameKey)
            let currentConversationContext = defaultContext.currentConversationContext

            // Recover oldest-first so summaries can build on each other naturally.
            let pendingChunks = pendingIndex.pendingChunks.sorted { $0.startDate < $1.startDate }

            for pending in pendingChunks {
                do {
                    // Load the raw messages
                    let fileURL = archiveFolder.appendingPathComponent(pending.rawContentFileName)
                    let data = try Data(contentsOf: fileURL)
                    let messages = try JSONDecoder().decode([Message].self, from: data)

                    let summariesBeforePending = chunkIndex.orderedChunks
                        .filter { $0.endDate < pending.startDate }
                        .map { $0.summary }

                    let recoveryContext = SummarizationContext(
                        personaContext: personaContext,
                        assistantName: assistantName,
                        userName: userName,
                        previousSummaries: summariesBeforePending,
                        currentConversationContext: currentConversationContext
                    )
                    
                    // Generate summary (with infinite retry)
                    var summary: String? = nil
                    var retryCount = 0
                    while summary == nil {
                        do {
                            summary = try await generateSummary(
                                for: messages,
                                startDate: pending.startDate,
                                endDate: pending.endDate,
                                context: recoveryContext
                            )
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
            
            // Clear pending chunk records and save
            pendingIndex.pendingChunks.removeAll()
            savePendingIndex()
            saveIndex()
        }

        // Check if consolidation is needed before recovering meta summaries,
        // so the historical consolidated set is up to date.
        await checkAndConsolidate()
        await recoverPendingMetaSummaries()
    }
    
    func configure(apiKey: String) {
        self.apiKey = apiKey
    }
    
    /// Reload chunk index and pending index from disk
    /// Call this after Mind restore to pick up the restored data
    func reloadFromDisk() {
        loadIndex()
        loadPendingIndex()
        loadPendingMetaIndex()
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
        pendingMetaIndex = .empty()
        cachedLiveContext = nil
        
        // Save empty indices
        saveIndex()
        savePendingIndex()
        savePendingMetaIndex()
        
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
        
        // Generate summary and extract user context facts in parallel
        async let summaryTask = generateSummary(for: messages, startDate: startDate, endDate: endDate, context: context)
        async let userContextTask: Void = extractAndAppendUserContext(messages: messages, startDate: startDate, endDate: endDate)

        let summary = try await summaryTask
        _ = await userContextTask
        
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

    /// Get the prompt-facing archived history timeline.
    /// Older consolidated chunks are compressed into chronological meta-summaries,
    /// while the most recent consolidated and temporary chunks remain visible individually.
    func getPromptSummaryItems(recentConsolidatedCount count: Int = 5) async -> [ArchivedSummaryItem] {
        await refreshHistoricalMetaSummariesIfNeeded(recentConsolidatedCount: count)

        let chunksById = Dictionary(uniqueKeysWithValues: chunkIndex.chunks.map { ($0.id, $0) })
        let consolidatedChunks = chunkIndex.chunks
            .filter { $0.type == .consolidated }
            .sorted { $0.startDate < $1.startDate }
        let recentConsolidatedChunks = Array(consolidatedChunks.suffix(count))
        let historicalConsolidatedChunks = Array(consolidatedChunks.dropLast(min(count, consolidatedChunks.count)))
        let temporaryChunks = chunkIndex.temporaryChunks

        let visibleMetaSummaries = Array(
            chunkIndex.historicalMetaSummaries
                .sorted { lhs, rhs in
                    if lhs.startDate != rhs.startDate {
                        return lhs.startDate < rhs.startDate
                    }
                    return lhs.endDate < rhs.endDate
                }
                .suffix(maxVisibleMetaSummaryCount)
        )

        let metaItems = visibleMetaSummaries
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                return lhs.endDate < rhs.endDate
            }
            .map { meta -> ArchivedSummaryItem in
                let childChunks = meta.childChunkIds.compactMap { chunksById[$0] }
                let tokenCount = childChunks.reduce(0) { $0 + $1.tokenCount }
                let messageCount = childChunks.reduce(0) { $0 + $1.messageCount }
                let kind: ArchivedSummaryItem.Kind = meta.kind == .rolling ? .rollingMetaSummary : .sealedMetaSummary

                return ArchivedSummaryItem(
                    id: meta.id,
                    kind: kind,
                    startDate: meta.startDate,
                    endDate: meta.endDate,
                    tokenCount: tokenCount,
                    messageCount: messageCount,
                    summary: meta.summary,
                    sourceChunkCount: max(meta.childChunkIds.count, 1)
                )
            }

        let representedHistoricalChunkIds = Set(
            chunkIndex.historicalMetaSummaries.flatMap(\.childChunkIds)
        )
        let uncoveredHistoricalItems = historicalConsolidatedChunks
            .filter { !representedHistoricalChunkIds.contains($0.id) }
            .map {
                ArchivedSummaryItem(
                    id: $0.id,
                    kind: .consolidatedChunk,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    tokenCount: $0.tokenCount,
                    messageCount: $0.messageCount,
                    summary: $0.summary,
                    sourceChunkCount: 1
                )
            }

        let chunkItems = recentConsolidatedChunks.map {
            ArchivedSummaryItem(
                id: $0.id,
                kind: .consolidatedChunk,
                startDate: $0.startDate,
                endDate: $0.endDate,
                tokenCount: $0.tokenCount,
                messageCount: $0.messageCount,
                summary: $0.summary,
                sourceChunkCount: 1
            )
        }

        let temporaryItems = temporaryChunks.map {
            ArchivedSummaryItem(
                id: $0.id,
                kind: .temporaryChunk,
                startDate: $0.startDate,
                endDate: $0.endDate,
                tokenCount: $0.tokenCount,
                messageCount: $0.messageCount,
                summary: $0.summary,
                sourceChunkCount: 1
            )
        }

        return (metaItems + uncoveredHistoricalItems + chunkItems + temporaryItems).sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate {
                return lhs.startDate < rhs.startDate
            }
            return lhs.endDate < rhs.endDate
        }
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
        
        let response = try await callLLM(systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: 2000)
        
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
                onStatusNotification?("🧠 Consolidating memory chunks...")
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

        // Restructure user context at consolidation time (~every 4 chunks).
        // After several append-only additions, the context may have duplicates or could
        // benefit from reorganization. This does a full intelligent merge.
        onStatusNotification?("🧠 Reorganizing user context...")
        await restructureUserContext()
    }

    private func refreshHistoricalMetaSummariesIfNeeded(recentConsolidatedCount: Int) async {
        let specs = desiredHistoricalMetaSummarySpecs(recentConsolidatedCount: recentConsolidatedCount)

        guard !specs.isEmpty else {
            if !chunkIndex.historicalMetaSummaries.isEmpty {
                chunkIndex.historicalMetaSummaries = []
                saveIndex()
            }
            if !pendingMetaIndex.pendingMetaSummaries.isEmpty {
                pendingMetaIndex.pendingMetaSummaries = []
                savePendingMetaIndex()
            }
            return
        }

        let existingSummaries = chunkIndex.historicalMetaSummaries
        var desiredSummaries: [HistoricalMetaSummary] = []
        let desiredSignatures = Set(
            specs.map { historicalMetaSummarySignature(kind: $0.kind, childChunkIds: $0.chunks.map(\.id)) }
        )

        for spec in specs {
            if let summary = await historicalMetaSummary(
                for: spec.chunks,
                kind: spec.kind,
                existingSummaries: existingSummaries
            ) {
                desiredSummaries.append(summary)
            }
        }

        desiredSummaries.sort { lhs, rhs in
            if lhs.startDate != rhs.startDate {
                return lhs.startDate < rhs.startDate
            }
            return lhs.endDate < rhs.endDate
        }

        if historicalMetaSummariesDiffer(existingSummaries, desiredSummaries) {
            chunkIndex.historicalMetaSummaries = desiredSummaries
            saveIndex()
            for summary in desiredSummaries {
                let signature = historicalMetaSummarySignature(kind: summary.kind, childChunkIds: summary.childChunkIds)
                clearPendingMetaSummary(signature: signature)
            }
        }

        let filteredPending = pendingMetaIndex.pendingMetaSummaries.filter {
            desiredSignatures.contains(historicalMetaSummarySignature(kind: $0.kind, childChunkIds: $0.childChunkIds))
        }
        if filteredPending.count != pendingMetaIndex.pendingMetaSummaries.count {
            pendingMetaIndex.pendingMetaSummaries = filteredPending
            savePendingMetaIndex()
        }
    }

    private func historicalMetaSummary(
        for chunks: [ConversationChunk],
        kind: HistoricalMetaSummary.MetaSummaryKind,
        existingSummaries: [HistoricalMetaSummary]
    ) async -> HistoricalMetaSummary? {
        guard let first = chunks.first, let last = chunks.last else { return nil }
        let context = buildHistoricalMetaSummaryContext(for: chunks)

        let signature = historicalMetaSummarySignature(kind: kind, childChunkIds: chunks.map(\.id))
        if let existing = existingSummaries.first(where: {
            historicalMetaSummarySignature(kind: $0.kind, childChunkIds: $0.childChunkIds) == signature
        }) {
            clearPendingMetaSummary(signature: signature)
            return existing
        }

        let pending = upsertPendingMetaSummary(for: chunks, kind: kind)

        var summary: String? = nil
        var retryCount = 0

        while summary == nil {
            do {
                try Task.checkCancellation()
                summary = try await generateHistoricalMetaSummary(for: chunks, kind: kind, context: context)
            } catch is CancellationError {
                return nil
            } catch {
                retryCount += 1
                let delay = min(2.0 * pow(2.0, Double(min(retryCount - 1, 5))), 60.0)
                print("[ArchiveService] \(kind == .rolling ? "Rolling" : "Sealed") meta-summary failed (attempt \(retryCount)): \(error). Retrying in \(Int(delay))s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        let now = Date()
        return HistoricalMetaSummary(
            id: pending.id,
            kind: kind,
            startDate: first.startDate,
            endDate: last.endDate,
            childChunkIds: chunks.map(\.id),
            summary: summary!,
            createdAt: pending.createdAt,
            updatedAt: now
        )
    }

    private func recoverPendingMetaSummaries(recentConsolidatedCount: Int = 5) async {
        guard !pendingMetaIndex.pendingMetaSummaries.isEmpty else { return }

        print("[ArchiveService] Found \(pendingMetaIndex.pendingMetaSummaries.count) pending meta-summary item(s), recovering...")

        let desiredSignatures = Set(
            desiredHistoricalMetaSummarySpecs(recentConsolidatedCount: recentConsolidatedCount).map {
                historicalMetaSummarySignature(kind: $0.kind, childChunkIds: $0.chunks.map(\.id))
            }
        )

        let chunksById = Dictionary(uniqueKeysWithValues: chunkIndex.chunks.map { ($0.id, $0) })

        for pending in pendingMetaIndex.pendingMetaSummaries.sorted(by: { $0.startDate < $1.startDate }) {
            let signature = historicalMetaSummarySignature(kind: pending.kind, childChunkIds: pending.childChunkIds)

            if chunkIndex.historicalMetaSummaries.contains(where: {
                historicalMetaSummarySignature(kind: $0.kind, childChunkIds: $0.childChunkIds) == signature
            }) {
                clearPendingMetaSummary(signature: signature)
                continue
            }

            guard desiredSignatures.contains(signature) else {
                print("[ArchiveService] Dropping stale pending meta-summary \(pending.id.uuidString.prefix(8))...")
                clearPendingMetaSummary(signature: signature)
                continue
            }

            let sourceChunks = pending.childChunkIds.compactMap { chunksById[$0] }
                .sorted { $0.startDate < $1.startDate }
            guard sourceChunks.count == pending.childChunkIds.count else {
                print("[ArchiveService] Pending meta-summary \(pending.id.uuidString.prefix(8))... is missing source chunks, dropping it")
                clearPendingMetaSummary(signature: signature)
                continue
            }

            let context = buildHistoricalMetaSummaryContext(for: sourceChunks)
            var summary: String? = nil
            var retryCount = 0

            while summary == nil {
                do {
                    try Task.checkCancellation()
                    summary = try await generateHistoricalMetaSummary(for: sourceChunks, kind: pending.kind, context: context)
                } catch is CancellationError {
                    return
                } catch {
                    retryCount += 1
                    let delay = min(2.0 * pow(2.0, Double(min(retryCount - 1, 5))), 60.0)
                    print("[ArchiveService] Pending meta-summary recovery failed (attempt \(retryCount)): \(error). Retrying in \(Int(delay))s...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }

            let completed = HistoricalMetaSummary(
                id: pending.id,
                kind: pending.kind,
                startDate: pending.startDate,
                endDate: pending.endDate,
                childChunkIds: pending.childChunkIds,
                summary: summary!,
                createdAt: pending.createdAt,
                updatedAt: Date()
            )

            chunkIndex.historicalMetaSummaries.removeAll {
                historicalMetaSummarySignature(kind: $0.kind, childChunkIds: $0.childChunkIds) == signature
            }
            chunkIndex.historicalMetaSummaries.append(completed)
            chunkIndex.historicalMetaSummaries.sort {
                if $0.startDate != $1.startDate {
                    return $0.startDate < $1.startDate
                }
                return $0.endDate < $1.endDate
            }
            saveIndex()
            clearPendingMetaSummary(signature: signature)
            print("[ArchiveService] Recovered pending meta-summary \(pending.id.uuidString.prefix(8))...")
        }
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
        You are summarizing a specific segment of an ongoing conversation. This summary will be used by you in the future to have a clear idea of the exact contents of this specific chunk of text. It doesn't have to be pretty, just compact, dense, full of all the information that it's worth keeping about the interaction with the user.\(contextBlock)
        YOUR TASK:
        Summarize ONLY the conversation segment below (make it a detailed ~1000 token summary, approximately 800 words).
        The summary should ONLY cover the messages in the segment being archived.
        The summary must be substantive and at least 600 words. 
        The summary should make chronology of events clear. Event after event.
        VERY IMPORTANT: You should cite the file names (in full with extension) of the most important files in this chunk so they can be easily referenced in the future (progect names don't have extensions). This applies to photos, documents and projects that were either sent by the user, generated by the assistant or the Code CLI or one of the tools, or received via email. For example if multiple attempts at editing an image happen, just cite the original image and the edited image that the user liked the most. The same with files. This is important. 
        This summary will replace the underlying chunk in your memory, so you should produce a summary that retains as much as possible. The goal is keeping this summary instead of the full underlying chunk to compress and free some LLM context space, but keeping everything that is important to let the LLM know exactly what the conversation said, what documents and photos are important for the continued conversation.
        """
        
        let userPrompt = """
        CONVERSATION SEGMENT TO SUMMARIZE
        Period: \(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))
        
        \(conversationText.prefix(100000))
        """
        
        let response = try await callLLM(systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: nil)
        let clippedResponse = String(response.prefix(summaryMaxCharacters))
        return try validateSummaryText(clippedResponse)
    }

    private func generateHistoricalMetaSummary(
        for chunks: [ConversationChunk],
        kind: HistoricalMetaSummary.MetaSummaryKind,
        context: SummarizationContext
    ) async throws -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        var contextSections: [String] = []

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

        if !context.previousSummaries.isEmpty {
            let summariesText = context.previousSummaries.enumerated().map { idx, summary in
                "[Chunk \(idx + 1)] \(summary)"
            }.joined(separator: "\n\n")
            contextSections.append("PREVIOUS CONVERSATION SUMMARIES:\n\(summariesText)")
        }

        if let current = context.currentConversationContext, !current.isEmpty {
            contextSections.append("CURRENT CONVERSATION (most recent, for context only):\n\(current)")
        }

        let contextBlock = contextSections.isEmpty ? "" : """

        === CONTEXT (for understanding only, DO NOT include in summary) ===
        \(contextSections.joined(separator: "\n\n"))
        === END CONTEXT ===

        """

        let sourceText = chunks.enumerated().map { index, chunk in
            """
            [Source \(index + 1)]
            Chunk ID: \(chunk.id.uuidString)
            Period: \(dateFormatter.string(from: chunk.startDate)) to \(dateFormatter.string(from: chunk.endDate))
            Tokens: \(chunk.tokenCount)
            Messages: \(chunk.messageCount)
            Summary:
            \(chunk.summary)
            """
        }.joined(separator: "\n\n")

        let kindLabel = kind == .rolling ? "rolling pre-batch summary" : "sealed historical meta-summary"
        let systemPrompt = """
        You are summarizing a specific historical span of an ongoing conversation. This summary will be used by you in the future to have a clear idea of the exact contents of this \(kindLabel). The source material below is already summarized conversation history rather than raw messages.\(contextBlock)
        YOUR TASK:
        Summarize ONLY the source chunk summaries below.
        The summary should ONLY cover the source chunk summaries in the batch being compressed.
        Preserve chronology of events clearly, event after event, from earliest to latest.
        Do not invent details not present in the source summaries.
        Merge repeated facts once, but make changes over time explicit.
        Keep durable context: people, relationships, projects, preferences, decisions, constraints, and unresolved threads.
        VERY IMPORTANT: You should cite the file names (in full with extension) of the most important files referenced in these source summaries so they can be easily referenced in the future (project names don't have extensions). This applies to photos, documents and projects that were either sent by the user, generated by the assistant or the Code CLI or one of the tools, or received via email.
        This summary will replace these underlying summaries in active prompt memory, so you should produce a compact but information-dense summary that retains as much as possible.
        Make it a detailed historical summary of roughly 500-800 words.
        """

        let userPrompt = """
        SOURCE CHUNK SUMMARIES
        Batch size: \(chunks.count)
        Covered period: \(dateFormatter.string(from: chunks.first!.startDate)) to \(dateFormatter.string(from: chunks.last!.endDate))

        \(sourceText.prefix(60000))
        """

        let response = try await callLLM(systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: 1400)
        let clippedResponse = String(response.prefix(summaryMaxCharacters))
        return try validateSummaryText(clippedResponse)
    }

    // MARK: - User Context Auto-Update
    //
    // Two-phase approach:
    //  1. APPEND-ONLY extraction (every chunk) — can only ADD new facts, never modify/delete.
    //     Safe, simple, impossible to corrupt existing context.
    //  2. RESTRUCTURE pass (at consolidation, every ~4 chunks) — full intelligent merge that
    //     deduplicates, corrects, reorganizes, and trims. Gets the COMPLETE existing context
    //     so nothing is lost — it just produces a cleaner version.

    /// Phase 1: Extract new durable facts from a conversation chunk and APPEND them.
    /// Cannot modify or delete existing context — only adds new lines.
    /// Runs in parallel with summary generation during archiveMessages().
    private func extractAndAppendUserContext(messages: [Message], startDate: Date, endDate: Date) async {
        let existingContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        let conversationText = await formatMessagesForSummary(messages)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let existingBlock: String
        if existingContext.isEmpty {
            existingBlock = "(No existing user context yet)"
        } else {
            existingBlock = """
            EXISTING USER CONTEXT (for dedup only — do NOT repeat what's already here):
            ---
            \(existingContext)
            ---
            """
        }

        let systemPrompt = """
        You are analyzing a conversation segment to extract NEW durable user-profile facts.

        \(existingBlock)

        OUTPUT FORMAT:
        - If there are NO new durable facts, respond with exactly: NO_CHANGES
        - If there ARE new facts, output ONLY the new lines to append (plain text, one fact per line). No JSON, no formatting, no headers. Just the raw facts.

        WHAT TO EXTRACT (only if not already in existing context):
        - Relationship network: family members, friends, frequent colleagues, nicknames, pets
        - Important places: homes, offices, frequently visited locations
        - Stable preferences: communication style, dietary, lifestyle, work habits
        - Recurring activities: hobbies, routines, regular commitments

        WHAT TO SKIP:
        - Anything already captured in the existing context above
        - One-off situational details, temporary opinions, task-specific context
        - Transient states (mood, current activity, what they're working on right now)
        """

        let userPrompt = """
        CONVERSATION SEGMENT
        Period: \(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))

        \(conversationText.prefix(100000))
        """

        // Infinite retry with exponential backoff (same pattern as historicalMetaSummary).
        var completed = false
        var retryCount = 0

        while !completed {
            do {
                try Task.checkCancellation()
                let response = try await callLLM(systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: 500)
                let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed == "NO_CHANGES" || trimmed.isEmpty {
                    completed = true
                    continue
                }

                // Re-read context fresh right before writing (avoid stale-read overwrites)
                let freshContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
                let updated = freshContext.isEmpty ? trimmed : freshContext + "\n" + trimmed

                // Enforce size limit (~5000 tokens)
                let capped = updated.count > 20000 ? String(updated.prefix(20000)) : updated

                try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: capped)
                print("[ArchiveService] User context: appended new facts from chunk")
                completed = true

            } catch is CancellationError {
                return
            } catch {
                retryCount += 1
                let delay = min(2.0 * pow(2.0, Double(min(retryCount - 1, 5))), 60.0)
                print("[ArchiveService] User context append failed (attempt \(retryCount)): \(error). Retrying in \(Int(delay))s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Phase 2: Restructure the user context — deduplicate, correct, reorganize, and trim.
    /// This is a full intelligent merge: the model receives the COMPLETE existing context and
    /// produces a clean, organized version. Nothing is lost — only redundancy is removed and
    /// structure is improved. Triggered at consolidation time (~every 4 chunks).
    private func restructureUserContext() async {
        let existingContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        guard !existingContext.isEmpty else { return }

        let maxChars = 20000
        let currentTokens = existingContext.count / 4

        let assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? ""
        let userName = KeychainHelper.load(key: KeychainHelper.userNameKey) ?? ""

        let systemPrompt = """
        You are reorganizing an AI assistant's persistent memory about the user.

        ⚠️ TOKEN LIMIT: ~5000 tokens (~20,000 characters). Currently using ~\(currentTokens) tokens.

        EXISTING CONTEXT (your ONLY source — do not invent anything):
        ---
        \(existingContext)
        ---

        YOUR TASK: Produce a clean, well-organized version of the SAME information.

        RULES:
        - PRESERVE every fact, relationship, preference, and detail from the existing context
        - Deduplicate: merge repeated or near-duplicate facts into single entries
        - Correct obvious inconsistencies (e.g., contradictory facts — keep the one that appears later/more recent)
        - Organize by categories (Personal, Relationships, Work, Preferences, Places, etc.) if not already organized
        - Written in second person ("You are...", "Your sister...")
        - Remove any contingent one-off details that don't belong in a durable profile
        - Stay within the token limit — be concise but NEVER drop important information
        - If the context is already clean and well-organized, reproduce it as-is

        Assistant Name: \(assistantName.isEmpty ? "not specified" : assistantName)
        User Name: \(userName.isEmpty ? "not specified" : userName)

        Output ONLY the final structured context. No explanations, no preamble.
        """

        // Infinite retry — restructuring is important for keeping context clean
        var completed = false
        var retryCount = 0

        while !completed {
            do {
                try Task.checkCancellation()
                let response = try await callLLM(systemPrompt: systemPrompt, userPrompt: "Restructure the user context above.", maxTokens: nil)
                let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !trimmed.isEmpty else {
                    // Empty response — retry
                    retryCount += 1
                    let delay = min(2.0 * pow(2.0, Double(min(retryCount - 1, 5))), 60.0)
                    print("[ArchiveService] User context restructure: empty response (attempt \(retryCount)). Retrying in \(Int(delay))s...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // Safety check: restructured context should not be dramatically shorter
                // (would indicate the model dropped information). Allow up to 40% shrinkage
                // from dedup/cleanup, but not more.
                let minAcceptableLength = existingContext.count * 3 / 5 // 60% of original
                if trimmed.count < minAcceptableLength && existingContext.count > 500 {
                    retryCount += 1
                    let delay = min(2.0 * pow(2.0, Double(min(retryCount - 1, 5))), 60.0)
                    print("[ArchiveService] User context restructure: result too short (\(trimmed.count) vs \(existingContext.count) original, min \(minAcceptableLength)). Retrying in \(Int(delay))s...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // Enforce size limit
                let capped = trimmed.count > maxChars ? String(trimmed.prefix(maxChars)) : trimmed

                try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: capped)
                print("[ArchiveService] User context restructured (\(existingContext.count) → \(capped.count) chars)")
                completed = true

            } catch is CancellationError {
                return
            } catch {
                retryCount += 1
                let delay = min(2.0 * pow(2.0, Double(min(retryCount - 1, 5))), 60.0)
                print("[ArchiveService] User context restructure failed (attempt \(retryCount)): \(error). Retrying in \(Int(delay))s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func buildHistoricalMetaSummaryContext(for batch: [ConversationChunk]) -> SummarizationContext {
        guard let first = batch.first, let last = batch.last else { return .empty }

        let personaContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey)
        let assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey)
        let userName = KeychainHelper.load(key: KeychainHelper.userNameKey)
        let batchIds = Set(batch.map(\.id))

        var previousSummaries: [String] = []
        var newerSummaries: [String] = []

        for chunk in chunkIndex.orderedChunks {
            guard !batchIds.contains(chunk.id) else { continue }

            if chunk.endDate < first.startDate {
                previousSummaries.append("[\(chunk.sizeLabel) chunk, \(formatDateRange(chunk.startDate, chunk.endDate))]: \(chunk.summary)")
            } else if chunk.startDate > last.endDate {
                newerSummaries.append("[\(chunk.sizeLabel) chunk, \(formatDateRange(chunk.startDate, chunk.endDate))]: \(chunk.summary)")
            }
        }

        var currentContextParts = newerSummaries
        if let liveContext = cachedLiveContext, !liveContext.isEmpty {
            currentContextParts.append("[CURRENT LIVE CONVERSATION]:\n\(liveContext)")
        }

        return SummarizationContext(
            personaContext: personaContext,
            assistantName: assistantName,
            userName: userName,
            previousSummaries: previousSummaries,
            currentConversationContext: currentContextParts.isEmpty ? nil : currentContextParts.joined(separator: "\n\n")
        )
    }

    private func desiredHistoricalMetaSummarySpecs(
        recentConsolidatedCount: Int
    ) -> [(kind: HistoricalMetaSummary.MetaSummaryKind, chunks: [ConversationChunk])] {
        let consolidatedChunks = chunkIndex.chunks
            .filter { $0.type == .consolidated }
            .sorted { $0.startDate < $1.startDate }
        let historicalCount = max(0, consolidatedChunks.count - recentConsolidatedCount)
        let historicalChunks = Array(consolidatedChunks.prefix(historicalCount))

        guard !historicalChunks.isEmpty else { return [] }

        var specs: [(kind: HistoricalMetaSummary.MetaSummaryKind, chunks: [ConversationChunk])] = []
        var index = 0

        while index + metaSummaryBatchSize <= historicalChunks.count {
            specs.append((
                kind: .sealedBatch,
                chunks: Array(historicalChunks[index..<(index + metaSummaryBatchSize)])
            ))
            index += metaSummaryBatchSize
        }

        let limboChunks = Array(historicalChunks.suffix(from: index))
        if limboChunks.count >= rollingMetaSummaryMinimumChunkCount {
            specs.append((kind: .rolling, chunks: limboChunks))
        }

        return specs
    }

    private func upsertPendingMetaSummary(
        for chunks: [ConversationChunk],
        kind: HistoricalMetaSummary.MetaSummaryKind
    ) -> PendingMetaSummary {
        let signature = historicalMetaSummarySignature(kind: kind, childChunkIds: chunks.map(\.id))
        if let existing = pendingMetaIndex.pendingMetaSummaries.first(where: {
            historicalMetaSummarySignature(kind: $0.kind, childChunkIds: $0.childChunkIds) == signature
        }) {
            return existing
        }

        let now = Date()
        let pending = PendingMetaSummary(
            id: UUID(),
            kind: kind,
            startDate: chunks.first!.startDate,
            endDate: chunks.last!.endDate,
            childChunkIds: chunks.map(\.id),
            createdAt: now,
            updatedAt: now
        )
        pendingMetaIndex.pendingMetaSummaries.append(pending)
        savePendingMetaIndex()
        return pending
    }

    private func clearPendingMetaSummary(signature: String) {
        let originalCount = pendingMetaIndex.pendingMetaSummaries.count
        pendingMetaIndex.pendingMetaSummaries.removeAll {
            historicalMetaSummarySignature(kind: $0.kind, childChunkIds: $0.childChunkIds) == signature
        }
        if pendingMetaIndex.pendingMetaSummaries.count != originalCount {
            savePendingMetaIndex()
        }
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
        
        let response = try await callLLM(systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: 4000)
        
        if let jsonData = extractFirstJSONObjectData(from: response) {
            struct ExcerptResult: Codable { let excerpts: [String] }
            if let result = try? JSONDecoder().decode(ExcerptResult.self, from: jsonData) {
                return result.excerpts
            }
        }
        
        return []
    }
    
    // MARK: - Archive LLM API
    
    private func callLLM(systemPrompt: String, userPrompt: String, maxTokens: Int?) async throws -> String {
        let usingLMStudio = isLMStudio

        if usingLMStudio && model.isEmpty {
            throw ArchiveError.notConfigured(reason: "LMStudio model name is not configured for archive operations")
        }

        if !usingLMStudio && apiKey.isEmpty {
            throw ArchiveError.notConfigured(reason: "OpenRouter API key is not configured for archive operations")
        }
        
        struct Request: Encodable {
            struct Message: Encodable { let role: String; let content: String }
            struct ReasoningConfig: Encodable { let effort: String }
            let model: String
            let messages: [Message]
            let max_tokens: Int?
            let temperature: Double
            let reasoning: ReasoningConfig?
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
            temperature: 0.3,
            reasoning: reasoningEffort.map { .init(effort: $0) }
        )
        
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if usingLMStudio {
            request.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("TelegramConcierge/1.0", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Telegram Concierge Bot", forHTTPHeaderField: "X-Title")
        }
        request.timeoutInterval = usingLMStudio ? 300 : 120
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
            let content = await decorateMessageContentForArchive(msg.content, message: msg)
            
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
            let content = await decorateMessageContentForArchive(msg.content, message: msg)
            
            formattedMessages.append("[\(time)] \(role): \(content)")
        }
        
        return formattedMessages.joined(separator: "\n\n")
    }

    private func decorateMessageContentForArchive(_ baseContent: String, message: Message) async -> String {
        var tags: [String] = []

        if !message.accessedProjectIds.isEmpty {
            tags.append("Projects accessed: \(message.accessedProjectIds.joined(separator: ", "))")
        }

        for fileName in message.imageFileNames {
            let desc = await FileDescriptionService.shared.get(filename: fileName)
            let descPart = desc.map { " - \"\($0)\"" } ?? ""
            tags.append("Image: \(fileName)\(descPart)")
        }

        for fileName in message.documentFileNames {
            let desc = await FileDescriptionService.shared.get(filename: fileName)
            let descPart = desc.map { " - \"\($0)\"" } ?? ""
            tags.append("Document: \(fileName)\(descPart)")
        }

        for fileName in message.referencedImageFileNames {
            let desc = await FileDescriptionService.shared.get(filename: fileName)
            let descPart = desc.map { " - \"\($0)\"" } ?? ""
            tags.append("Referenced image: \(fileName)\(descPart)")
        }

        for fileName in message.referencedDocumentFileNames {
            let desc = await FileDescriptionService.shared.get(filename: fileName)
            let descPart = desc.map { " - \"\($0)\"" } ?? ""
            tags.append("Referenced document: \(fileName)\(descPart)")
        }

        for fileName in message.downloadedDocumentFileNames {
            let desc = await FileDescriptionService.shared.get(filename: fileName)
            let descPart = desc.map { " - \"\($0)\"" } ?? ""
            tags.append("Downloaded file: \(fileName)\(descPart)")
        }

        guard !tags.isEmpty else { return baseContent }
        let prefix = tags.map { "[\($0)]" }.joined(separator: " ")
        return "\(prefix) \(baseContent)"
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

    private func validateSummaryText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ArchiveError.emptySummary
        }

        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= minimumSummaryWordCount else {
            throw ArchiveError.summaryTooShort(actualWords: wordCount, minimumWords: minimumSummaryWordCount)
        }

        return trimmed
    }

    private func historicalMetaSummarySignature(
        kind: HistoricalMetaSummary.MetaSummaryKind,
        childChunkIds: [UUID]
    ) -> String {
        let ids = childChunkIds.map(\.uuidString).joined(separator: ",")
        return "\(kind.rawValue)|\(ids)"
    }

    private func historicalMetaSummariesDiffer(
        _ lhs: [HistoricalMetaSummary],
        _ rhs: [HistoricalMetaSummary]
    ) -> Bool {
        guard lhs.count == rhs.count else { return true }

        for (left, right) in zip(lhs, rhs) {
            if left.kind != right.kind ||
                left.startDate != right.startDate ||
                left.endDate != right.endDate ||
                left.childChunkIds != right.childChunkIds ||
                left.summary != right.summary {
                return true
            }
        }

        return false
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

    private func loadPendingMetaIndex() {
        guard FileManager.default.fileExists(atPath: pendingMetaIndexFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: pendingMetaIndexFileURL)
            pendingMetaIndex = try JSONDecoder().decode(PendingMetaSummaryIndex.self, from: data)
            if !pendingMetaIndex.pendingMetaSummaries.isEmpty {
                print("[ArchiveService] Loaded \(pendingMetaIndex.pendingMetaSummaries.count) pending meta-summary item(s) awaiting recovery")
            }
        } catch {
            print("[ArchiveService] Failed to load pending meta-summary index: \(error)")
        }
    }

    private func savePendingMetaIndex() {
        do {
            let data = try JSONEncoder().encode(pendingMetaIndex)
            try data.write(to: pendingMetaIndexFileURL)
        } catch {
            print("[ArchiveService] Failed to save pending meta-summary index: \(error)")
        }
    }
}

// MARK: - Errors

enum ArchiveError: LocalizedError {
    case emptyMessages
    case chunkNotFound
    case fileNotFound(path: String)
    case notConfigured(reason: String)
    case apiError
    case emptySummary
    case summaryTooShort(actualWords: Int, minimumWords: Int)
    
    var errorDescription: String? {
        switch self {
        case .emptyMessages: return "Cannot archive empty message list"
        case .chunkNotFound: return "Chunk not found in archive"
        case .fileNotFound(let path): return "Chunk file not found at: \(path)"
        case .notConfigured(let reason): return reason
        case .apiError: return "API call failed"
        case .emptySummary: return "Summary generation returned empty output"
        case .summaryTooShort(let actualWords, let minimumWords):
            return "Summary too short (\(actualWords) words). Minimum required: \(minimumWords) words"
        }
    }
}
