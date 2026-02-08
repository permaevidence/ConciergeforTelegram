import Foundation

// MARK: - Conversation Chunk Model

/// Represents an archived segment of conversation history
struct ConversationChunk: Codable, Identifiable {
    let id: UUID
    let type: ChunkType
    let startDate: Date
    let endDate: Date
    let tokenCount: Int
    let messageCount: Int
    let summary: String
    let rawContentFileName: String
    
    enum ChunkType: String, Codable {
        case temporary    // Size based on user setting (default 25k)
        case consolidated // 4 temporary chunks merged
    }
    
    /// Display-friendly size label based on actual token count
    var sizeLabel: String {
        if tokenCount >= 1000 {
            return "\(tokenCount / 1000)k"
        } else {
            return "\(tokenCount)"
        }
    }
}

// MARK: - Chunk Index (persisted list of all chunks)

struct ChunkIndex: Codable {
    var chunks: [ConversationChunk]
    
    static func empty() -> ChunkIndex {
        ChunkIndex(chunks: [])
    }
    
    /// Get chunks ordered by date (oldest first)
    var orderedChunks: [ConversationChunk] {
        chunks.sorted { $0.startDate < $1.startDate }
    }
    
    /// Get the most recent N chunks (newest last)
    func recentChunks(count: Int) -> [ConversationChunk] {
        Array(orderedChunks.suffix(count))
    }
    
    /// Get temporary chunks that might be ready for consolidation
    var temporaryChunks: [ConversationChunk] {
        chunks.filter { $0.type == .temporary }.sorted { $0.startDate < $1.startDate }
    }
}

// MARK: - Chunk Search Result

struct ChunkSearchResult: Codable {
    let chunkId: UUID
    let excerpts: [String]
    let relevanceScore: Double?
}

// MARK: - Chunk Identifier (for summary-based search)

struct ChunkIdentification: Codable {
    let chunkId: String
    let relevance: String
}

struct ChunkIdentificationResult: Codable {
    let relevantChunks: [ChunkIdentification]
    
    enum CodingKeys: String, CodingKey {
        case relevantChunks = "relevant_chunks"
    }
}

// MARK: - Summary Extraction Result

struct SummaryExtractionResult: Codable {
    let summary: String
    let keyTopics: [String]
    
    enum CodingKeys: String, CodingKey {
        case summary
        case keyTopics = "key_topics"
    }
}

// MARK: - Pending Chunk (for crash recovery)

/// Represents a chunk that has been saved to disk but not yet summarized
/// Used to recover from crashes during summarization
struct PendingChunk: Codable, Identifiable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let tokenCount: Int
    let messageCount: Int
    let rawContentFileName: String
    let createdAt: Date
}

struct PendingChunkIndex: Codable {
    var pendingChunks: [PendingChunk]
    
    static func empty() -> PendingChunkIndex {
        PendingChunkIndex(pendingChunks: [])
    }
}

