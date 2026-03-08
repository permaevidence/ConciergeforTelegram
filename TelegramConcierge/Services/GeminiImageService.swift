import Foundation

/// Service for generating images using a configurable Gemini image model
actor GeminiImageService {
    static let shared = GeminiImageService()
    
    private var apiKey: String = ""
    private var model: String = "gemini-3-pro-image-preview"
    private var pricing = GeminiImagePricing.default
    
    func configure(apiKey: String, model: String? = nil, pricing: GeminiImagePricing? = nil) {
        self.apiKey = apiKey
        if let model {
            let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            self.model = normalizedModel.isEmpty ? GeminiImagePricing.defaultModel : normalizedModel
        } else {
            self.model = GeminiImagePricing.defaultModel
        }
        self.pricing = pricing ?? .default
    }
    
    func isConfigured() -> Bool {
        !apiKey.isEmpty
    }
    
    /// Generate an image from a text prompt, optionally using a source image for transformation
    /// - Parameters:
    ///   - prompt: The text description of the image to generate or transformation to apply
    ///   - sourceImageData: Optional source image data for image-to-image transformation
    ///   - sourceMimeType: MIME type of the source image (e.g., "image/jpeg", "image/png")
    ///   - imageSize: Optional image size override. Supported values: 1K, 2K, 4K.
    /// - Returns: Image data (PNG/JPEG), MIME type, and estimated Gemini API spend in USD
    func generateImage(
        prompt: String,
        sourceImageData: Data? = nil,
        sourceMimeType: String? = nil,
        imageSize: String? = nil
    ) async throws -> (data: Data, mimeType: String, spendUSD: Double?) {
        guard !apiKey.isEmpty else {
            throw GeminiImageError.notConfigured
        }
        
        // Build request URL with API key
        let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard var urlComponents = URLComponents(string: baseURL) else {
            throw GeminiImageError.invalidURL
        }
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        
        guard let url = urlComponents.url else {
            throw GeminiImageError.invalidURL
        }
        
        // Build parts array - text prompt + optional source image
        var parts: [GeminiPart] = []
        
        // Add source image first if provided (Gemini expects image before text for editing)
        if let imageData = sourceImageData, let mimeType = sourceMimeType {
            let base64Image = imageData.base64EncodedString()
            let inlineData = GeminiInlineData(mimeType: mimeType, data: base64Image)
            parts.append(GeminiPart(inlineData: inlineData))
        }
        
        // Add text prompt
        parts.append(GeminiPart(text: prompt))
        
        // Build request body
        let requestBody = GeminiImageRequest(
            contents: [
                GeminiContent(parts: parts)
            ],
            generationConfig: GeminiGenerationConfig(
                responseModalities: ["TEXT", "IMAGE"],
                imageConfig: imageSize.map { GeminiImageConfig(imageSize: $0) }
            )
        )
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60  // Image generation can take time
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiImageError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            // Try to parse error message
            if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
                throw GeminiImageError.apiError(errorResponse.error.message)
            }
            throw GeminiImageError.httpError(httpResponse.statusCode)
        }
        
        // Parse response
        let geminiResponse = try JSONDecoder().decode(GeminiImageResponse.self, from: data)
        let spendUSD = estimatedSpendUSD(
            from: geminiResponse.usageMetadata,
            imageSize: imageSize
        )
        
        // Find the image part in the response
        for candidate in geminiResponse.candidates ?? [] {
            for part in candidate.content?.parts ?? [] {
                if let inlineData = part.inlineData {
                    guard let imageData = Data(base64Encoded: inlineData.data) else {
                        throw GeminiImageError.invalidImageData
                    }
                    return (imageData, inlineData.mimeType, spendUSD)
                }
            }
        }
        
        throw GeminiImageError.noImageGenerated
    }

    private func estimatedSpendUSD(
        from usageMetadata: GeminiUsageMetadata?,
        imageSize: String?
    ) -> Double? {
        var totalUSD = 0.0
        var didCalculate = false

        if let promptTokenCount = usageMetadata?.promptTokenCount,
           promptTokenCount > 0 {
            totalUSD += (Double(promptTokenCount) / 1_000_000.0) * pricing.inputCostPerMillionTokensUSD
            didCalculate = true
        }

        let candidateDetails = usageMetadata?.candidatesTokensDetails ?? []
        let candidateTextTokens = candidateDetails
            .filter { $0.modality == .text }
            .reduce(0) { $0 + $1.tokenCount }
        if candidateTextTokens > 0 {
            totalUSD += (Double(candidateTextTokens) / 1_000_000.0) * pricing.outputTextCostPerMillionTokensUSD
            didCalculate = true
        }

        let candidateImageTokens = candidateDetails
            .filter { $0.modality == .image }
            .reduce(0) { $0 + $1.tokenCount }
        if candidateImageTokens > 0 {
            totalUSD += (Double(candidateImageTokens) / 1_000_000.0) * pricing.outputImageCostPerMillionTokensUSD
            didCalculate = true
        } else if let fallbackImageTokens = fallbackImageTokenCount(for: imageSize) {
            totalUSD += (Double(fallbackImageTokens) / 1_000_000.0) * pricing.outputImageCostPerMillionTokensUSD
            didCalculate = true
        }

        guard didCalculate, totalUSD.isFinite, totalUSD > 0 else { return nil }
        return totalUSD
    }

    private func fallbackImageTokenCount(for imageSize: String?) -> Int? {
        guard let parsedSize = GeminiImageSize.parse(imageSize) else { return nil }
        switch parsedSize {
        case .oneK, .twoK:
            return 1120
        case .fourK:
            return 2000
        }
    }
}

struct GeminiImagePricing {
    static let defaultModel = "gemini-3-pro-image-preview"
    static let `default` = GeminiImagePricing(
        inputCostPerMillionTokensUSD: 2.0,
        outputTextCostPerMillionTokensUSD: 12.0,
        outputImageCostPerMillionTokensUSD: 120.0
    )

    let inputCostPerMillionTokensUSD: Double
    let outputTextCostPerMillionTokensUSD: Double
    let outputImageCostPerMillionTokensUSD: Double
}

// MARK: - Error Types

enum GeminiImageError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case apiError(String)
    case invalidImageData
    case noImageGenerated
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Gemini API key is not configured"
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from Gemini API"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .apiError(let message):
            return "Gemini API error: \(message)"
        case .invalidImageData:
            return "Failed to decode image data"
        case .noImageGenerated:
            return "No image was generated in the response"
        }
    }
}

// MARK: - Request Models

struct GeminiImageRequest: Codable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
}

struct GeminiContent: Codable {
    let parts: [GeminiPart]
}

struct GeminiPart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
    
    init(text: String) {
        self.text = text
        self.inlineData = nil
    }
    
    init(inlineData: GeminiInlineData) {
        self.text = nil
        self.inlineData = inlineData
    }
}

struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String  // Base64 encoded
}

struct GeminiGenerationConfig: Codable {
    let responseModalities: [String]
    let imageConfig: GeminiImageConfig?
}

struct GeminiImageConfig: Codable {
    let imageSize: String
}

enum GeminiImageSize: String {
    case oneK = "1K"
    case twoK = "2K"
    case fourK = "4K"
    
    static func parse(_ rawValue: String?) -> GeminiImageSize? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        
        guard !normalized.isEmpty else { return nil }
        
        switch normalized {
        case "1K", "1", "1024":
            return .oneK
        case "2K", "2", "2048":
            return .twoK
        case "4K", "4", "4096", "UHD", "ULTRAHD", "ULTRA":
            return .fourK
        default:
            return nil
        }
    }
}

// MARK: - Response Models

struct GeminiImageResponse: Codable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsageMetadata?

    enum CodingKeys: String, CodingKey {
        case candidates
        case usageMetadata = "usageMetadata"
    }
}

struct GeminiCandidate: Codable {
    let content: GeminiResponseContent?
}

struct GeminiResponseContent: Codable {
    let parts: [GeminiResponsePart]?
}

struct GeminiResponsePart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
}

struct GeminiUsageMetadata: Codable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let totalTokenCount: Int?
    let promptTokensDetails: [GeminiModalityTokenCount]?
    let candidatesTokensDetails: [GeminiModalityTokenCount]?

    enum CodingKeys: String, CodingKey {
        case promptTokenCount = "promptTokenCount"
        case candidatesTokenCount = "candidatesTokenCount"
        case totalTokenCount = "totalTokenCount"
        case promptTokensDetails = "promptTokensDetails"
        case candidatesTokensDetails = "candidatesTokensDetails"
    }
}

struct GeminiModalityTokenCount: Codable {
    let modality: GeminiTokenModality
    let tokenCount: Int

    enum CodingKeys: String, CodingKey {
        case modality
        case tokenCount = "tokenCount"
    }
}

enum GeminiTokenModality: String, Codable {
    case text = "TEXT"
    case image = "IMAGE"
    case audio = "AUDIO"
    case video = "VIDEO"
    case unspecified = "MODALITY_UNSPECIFIED"
}

struct GeminiErrorResponse: Codable {
    let error: GeminiError
}

struct GeminiError: Codable {
    let code: Int
    let message: String
    let status: String?
}
