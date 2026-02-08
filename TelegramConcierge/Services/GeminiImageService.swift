import Foundation

/// Service for generating images using Google's Gemini 2.0 Flash model
actor GeminiImageService {
    static let shared = GeminiImageService()
    
    private var apiKey: String = ""
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-image-preview:generateContent"
    
    func configure(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func isConfigured() -> Bool {
        !apiKey.isEmpty
    }
    
    /// Generate an image from a text prompt, optionally using a source image for transformation
    /// - Parameters:
    ///   - prompt: The text description of the image to generate or transformation to apply
    ///   - sourceImageData: Optional source image data for image-to-image transformation
    ///   - sourceMimeType: MIME type of the source image (e.g., "image/jpeg", "image/png")
    /// - Returns: Image data (PNG/JPEG) and MIME type
    func generateImage(prompt: String, sourceImageData: Data? = nil, sourceMimeType: String? = nil) async throws -> (data: Data, mimeType: String) {
        guard !apiKey.isEmpty else {
            throw GeminiImageError.notConfigured
        }
        
        // Build request URL with API key
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
                responseModalities: ["TEXT", "IMAGE"]
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
        
        // Find the image part in the response
        for candidate in geminiResponse.candidates ?? [] {
            for part in candidate.content?.parts ?? [] {
                if let inlineData = part.inlineData {
                    guard let imageData = Data(base64Encoded: inlineData.data) else {
                        throw GeminiImageError.invalidImageData
                    }
                    return (imageData, inlineData.mimeType)
                }
            }
        }
        
        throw GeminiImageError.noImageGenerated
    }
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
}

// MARK: - Response Models

struct GeminiImageResponse: Codable {
    let candidates: [GeminiCandidate]?
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

struct GeminiErrorResponse: Codable {
    let error: GeminiError
}

struct GeminiError: Codable {
    let code: Int
    let message: String
    let status: String?
}
