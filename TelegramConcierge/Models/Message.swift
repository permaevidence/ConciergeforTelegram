import Foundation

struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    
    // Multiple attachments support (primary storage)
    let imageFileNames: [String]
    let documentFileNames: [String]
    let imageFileSizes: [Int]
    let documentFileSizes: [Int]
    
    // Referenced attachments from replied-to messages (also multiple)
    let referencedImageFileNames: [String]
    let referencedDocumentFileNames: [String]
    let referencedImageFileSizes: [Int]
    let referencedDocumentFileSizes: [Int]
    
    // Files downloaded via tools (email attachments, URL downloads, etc.)
    var downloadedDocumentFileNames: [String]
    
    enum Role: String, Codable {
        case user
        case assistant
    }
    
    // MARK: - Convenience accessors for single-attachment cases
    
    var imageFileName: String? { imageFileNames.first }
    var documentFileName: String? { documentFileNames.first }
    var imageFileSize: Int? { imageFileSizes.first }
    var documentFileSize: Int? { documentFileSizes.first }
    var referencedImageFileName: String? { referencedImageFileNames.first }
    var referencedDocumentFileName: String? { referencedDocumentFileNames.first }
    var referencedImageFileSize: Int? { referencedImageFileSizes.first }
    var referencedDocumentFileSize: Int? { referencedDocumentFileSizes.first }
    
    // MARK: - Initializers
    
    /// Full initializer with array support
    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        imageFileNames: [String] = [],
        documentFileNames: [String] = [],
        imageFileSizes: [Int] = [],
        documentFileSizes: [Int] = [],
        referencedImageFileNames: [String] = [],
        referencedDocumentFileNames: [String] = [],
        referencedImageFileSizes: [Int] = [],
        referencedDocumentFileSizes: [Int] = [],
        downloadedDocumentFileNames: [String] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.imageFileNames = imageFileNames
        self.documentFileNames = documentFileNames
        self.imageFileSizes = imageFileSizes
        self.documentFileSizes = documentFileSizes
        self.referencedImageFileNames = referencedImageFileNames
        self.referencedDocumentFileNames = referencedDocumentFileNames
        self.referencedImageFileSizes = referencedImageFileSizes
        self.referencedDocumentFileSizes = referencedDocumentFileSizes
        self.downloadedDocumentFileNames = downloadedDocumentFileNames
    }
    
    // MARK: - Codable (with backward compatibility)
    
    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
        // New array fields
        case imageFileNames, documentFileNames, imageFileSizes, documentFileSizes
        case referencedImageFileNames, referencedDocumentFileNames
        case referencedImageFileSizes, referencedDocumentFileSizes
        case downloadedDocumentFileNames
        // Legacy single-value fields (for decoding old data)
        case imageFileName, documentFileName, imageFileSize, documentFileSize
        case referencedImageFileName, referencedDocumentFileName
        case referencedImageFileSize, referencedDocumentFileSize
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        
        // Try new array format first, fall back to legacy single-value format
        if let names = try? container.decode([String].self, forKey: .imageFileNames) {
            imageFileNames = names
        } else if let name = try? container.decodeIfPresent(String.self, forKey: .imageFileName) {
            imageFileNames = [name]
        } else {
            imageFileNames = []
        }
        
        if let names = try? container.decode([String].self, forKey: .documentFileNames) {
            documentFileNames = names
        } else if let name = try? container.decodeIfPresent(String.self, forKey: .documentFileName) {
            documentFileNames = [name]
        } else {
            documentFileNames = []
        }
        
        if let sizes = try? container.decode([Int].self, forKey: .imageFileSizes) {
            imageFileSizes = sizes
        } else if let size = try? container.decodeIfPresent(Int.self, forKey: .imageFileSize) {
            imageFileSizes = [size]
        } else {
            imageFileSizes = []
        }
        
        if let sizes = try? container.decode([Int].self, forKey: .documentFileSizes) {
            documentFileSizes = sizes
        } else if let size = try? container.decodeIfPresent(Int.self, forKey: .documentFileSize) {
            documentFileSizes = [size]
        } else {
            documentFileSizes = []
        }
        
        // Referenced attachments
        if let names = try? container.decode([String].self, forKey: .referencedImageFileNames) {
            referencedImageFileNames = names
        } else if let name = try? container.decodeIfPresent(String.self, forKey: .referencedImageFileName) {
            referencedImageFileNames = [name]
        } else {
            referencedImageFileNames = []
        }
        
        if let names = try? container.decode([String].self, forKey: .referencedDocumentFileNames) {
            referencedDocumentFileNames = names
        } else if let name = try? container.decodeIfPresent(String.self, forKey: .referencedDocumentFileName) {
            referencedDocumentFileNames = [name]
        } else {
            referencedDocumentFileNames = []
        }
        
        if let sizes = try? container.decode([Int].self, forKey: .referencedImageFileSizes) {
            referencedImageFileSizes = sizes
        } else if let size = try? container.decodeIfPresent(Int.self, forKey: .referencedImageFileSize) {
            referencedImageFileSizes = [size]
        } else {
            referencedImageFileSizes = []
        }
        
        if let sizes = try? container.decode([Int].self, forKey: .referencedDocumentFileSizes) {
            referencedDocumentFileSizes = sizes
        } else if let size = try? container.decodeIfPresent(Int.self, forKey: .referencedDocumentFileSize) {
            referencedDocumentFileSizes = [size]
        } else {
            referencedDocumentFileSizes = []
        }
        
        // Downloaded files (new field, default to empty for old messages)
        downloadedDocumentFileNames = (try? container.decode([String].self, forKey: .downloadedDocumentFileNames)) ?? []
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        
        // Always encode in new array format
        try container.encode(imageFileNames, forKey: .imageFileNames)
        try container.encode(documentFileNames, forKey: .documentFileNames)
        try container.encode(imageFileSizes, forKey: .imageFileSizes)
        try container.encode(documentFileSizes, forKey: .documentFileSizes)
        try container.encode(referencedImageFileNames, forKey: .referencedImageFileNames)
        try container.encode(referencedDocumentFileNames, forKey: .referencedDocumentFileNames)
        try container.encode(referencedImageFileSizes, forKey: .referencedImageFileSizes)
        try container.encode(referencedDocumentFileSizes, forKey: .referencedDocumentFileSizes)
        try container.encode(downloadedDocumentFileNames, forKey: .downloadedDocumentFileNames)
    }
}
