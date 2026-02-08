import Foundation

actor TelegramBotService {
    private let baseURL = "https://api.telegram.org/bot"
    private var botToken: String = ""
    private var lastUpdateId: Int = 0
    
    func configure(token: String) {
        self.botToken = token
    }
    
    // MARK: - Error Handling Helper
    
    private func throwInvalidResponse(_ response: URLResponse?, data: Data) throws -> Never {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8)
        throw TelegramError.invalidResponse(statusCode: statusCode, body: body)
    }
    
    /// Test the bot token by calling getMe endpoint
    func getMe(token: String) async throws -> TelegramBotInfo {
        let url = URL(string: "\(baseURL)\(token)/getMe")!
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        let decoded = try JSONDecoder().decode(TelegramResponse<TelegramBotInfo>.self, from: data)
        
        guard decoded.ok, let botInfo = decoded.result else {
            throw TelegramError.apiError(decoded.description ?? "Invalid token")
        }
        
        return botInfo
    }
    func getUpdates() async throws -> [TelegramUpdate] {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }
        
        var urlComponents = URLComponents(string: "\(baseURL)\(botToken)/getUpdates")!
        urlComponents.queryItems = [
            URLQueryItem(name: "offset", value: String(lastUpdateId + 1)),
            URLQueryItem(name: "timeout", value: "0"),  // Instant return for 1-second polling
            URLQueryItem(name: "allowed_updates", value: "[\"message\"]")
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.timeoutInterval = 10
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        let decoded = try JSONDecoder().decode(TelegramResponse<[TelegramUpdate]>.self, from: data)
        
        guard decoded.ok, let updates = decoded.result else {
            throw TelegramError.apiError(decoded.description ?? "Unknown error")
        }
        
        if let lastUpdate = updates.last {
            lastUpdateId = lastUpdate.updateId
        }
        
        return updates
    }
    
    func sendMessage(chatId: Int, text: String) async throws {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }
        
        let url = URL(string: "\(baseURL)\(botToken)/sendMessage")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Try with Markdown parse mode first for nice formatting
        let body = TelegramSendMessageRequest(
            chatId: chatId,
            text: text,
            parseMode: "Markdown"
        )
        
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // If Markdown parsing fails, retry without parse mode
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 400 {
            // Telegram returns 400 if markdown is invalid - retry as plain text
            let plainBody = TelegramSendMessageRequest(
                chatId: chatId,
                text: text,
                parseMode: nil
            )
            request.httpBody = try JSONEncoder().encode(plainBody)
            
            let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
            
            guard let retryHttpResponse = retryResponse as? HTTPURLResponse,
                  retryHttpResponse.statusCode == 200 else {
                try throwInvalidResponse(retryResponse, data: retryData)
            }
            
            let retryDecoded = try JSONDecoder().decode(TelegramResponse<TelegramMessage>.self, from: retryData)
            
            guard retryDecoded.ok else {
                throw TelegramError.apiError(retryDecoded.description ?? "Failed to send message")
            }
            return
        }
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        let decoded = try JSONDecoder().decode(TelegramResponse<TelegramMessage>.self, from: data)
        
        guard decoded.ok else {
            throw TelegramError.apiError(decoded.description ?? "Failed to send message")
        }
    }
    
    func resetOffset() {
        lastUpdateId = 0
    }
    
    // MARK: - Voice File Download
    
    func getFile(fileId: String) async throws -> TelegramFile {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }
        
        var urlComponents = URLComponents(string: "\(baseURL)\(botToken)/getFile")!
        urlComponents.queryItems = [
            URLQueryItem(name: "file_id", value: fileId)
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.timeoutInterval = 30
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        let decoded = try JSONDecoder().decode(TelegramResponse<TelegramFile>.self, from: data)
        
        guard decoded.ok, let file = decoded.result else {
            throw TelegramError.apiError(decoded.description ?? "Failed to get file info")
        }
        
        return file
    }
    
    func downloadVoiceFile(fileId: String) async throws -> URL {
        let file = try await getFile(fileId: fileId)
        
        guard let filePath = file.filePath else {
            throw TelegramError.apiError("No file path returned from Telegram")
        }
        
        // Build the download URL
        let downloadURLString = "https://api.telegram.org/file/bot\(botToken)/\(filePath)"
        guard let downloadURL = URL(string: downloadURLString) else {
            throw TelegramError.apiError("Invalid download URL")
        }
        
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 60
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        // Save to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let localURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("ogg")
        try data.write(to: localURL)
        
        return localURL
    }
    
    func downloadPhoto(fileId: String) async throws -> Data {
        let file = try await getFile(fileId: fileId)
        
        guard let filePath = file.filePath else {
            throw TelegramError.apiError("No file path returned from Telegram")
        }
        
        // Build the download URL
        let downloadURLString = "https://api.telegram.org/file/bot\(botToken)/\(filePath)"
        guard let downloadURL = URL(string: downloadURLString) else {
            throw TelegramError.apiError("Invalid download URL")
        }
        
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 60
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        return data
    }
    
    /// Download a document (any file type) from Telegram
    func downloadDocument(fileId: String) async throws -> Data {
        let file = try await getFile(fileId: fileId)
        
        guard let filePath = file.filePath else {
            throw TelegramError.apiError("No file path returned from Telegram")
        }
        
        // Build the download URL
        let downloadURLString = "https://api.telegram.org/file/bot\(botToken)/\(filePath)"
        guard let downloadURL = URL(string: downloadURLString) else {
            throw TelegramError.apiError("Invalid download URL")
        }
        
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 120  // Longer timeout for larger files
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        return data
    }
    
    // MARK: - Send Photo
    
    /// Send a photo to a chat
    func sendPhoto(chatId: Int, imageData: Data, caption: String? = nil, mimeType: String = "image/png") async throws {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }
        
        let url = URL(string: "\(baseURL)\(botToken)/sendPhoto")!
        
        // Create multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        
        var body = Data()
        
        // Add chat_id field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(chatId)\r\n".data(using: .utf8)!)
        
        // Add photo file
        let fileExtension = mimeType.contains("jpeg") || mimeType.contains("jpg") ? "jpg" : "png"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"image.\(fileExtension)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add caption if provided
        if let caption = caption {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(caption)\r\n".data(using: .utf8)!)
        }
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        let decoded = try JSONDecoder().decode(TelegramResponse<TelegramMessage>.self, from: data)
        
        guard decoded.ok else {
            throw TelegramError.apiError(decoded.description ?? "Failed to send photo")
        }
    }
    
    // MARK: - Send Document
    
    /// Send a document/file to a chat
    func sendDocument(chatId: Int, documentData: Data, filename: String, caption: String? = nil, mimeType: String = "application/octet-stream") async throws {
        guard !botToken.isEmpty else {
            throw TelegramError.notConfigured
        }
        
        let url = URL(string: "\(baseURL)\(botToken)/sendDocument")!
        
        // Create multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120  // Longer timeout for larger files
        
        var body = Data()
        
        // Add chat_id field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(chatId)\r\n".data(using: .utf8)!)
        
        // Add document file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"document\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(documentData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add caption if provided
        if let caption = caption {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(caption)\r\n".data(using: .utf8)!)
        }
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try throwInvalidResponse(response, data: data)
        }
        
        let decoded = try JSONDecoder().decode(TelegramResponse<TelegramMessage>.self, from: data)
        
        guard decoded.ok else {
            throw TelegramError.apiError(decoded.description ?? "Failed to send document")
        }
    }
}

enum TelegramError: LocalizedError {
    case notConfigured
    case invalidResponse(statusCode: Int, body: String?)
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Telegram bot is not configured"
        case .invalidResponse(let statusCode, let body):
            if let body = body, !body.isEmpty {
                return "Telegram API error (HTTP \(statusCode)): \(body.prefix(200))"
            }
            return "Telegram API error (HTTP \(statusCode))"
        case .apiError(let message):
            return "Telegram API error: \(message)"
        }
    }
}
