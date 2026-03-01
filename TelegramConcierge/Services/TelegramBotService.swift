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

    /// Convert model-generated Markdown-like content into plain Telegram-friendly text.
    /// Telegram's parser does not support many common Markdown constructs (headings, **bold**, etc.),
    /// which can leak raw markers to end users.
    private func normalizeTelegramText(_ text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Normalize line-level structures first.
        let normalizedLines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                var line = String(rawLine)

                // Strip Markdown headings like "### Title".
                line = line.replacingRegexMatches(of: #"^\s{0,3}#{1,6}\s*"#, with: "")
                // Convert Markdown bullets into plain ASCII bullets.
                line = line.replacingRegexMatches(of: #"^\s*[-*+]\s+"#, with: "- ")
                // Remove blockquote markers.
                line = line.replacingRegexMatches(of: #"^\s*>\s?"#, with: "")

                // Remove code fence delimiter lines.
                if line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                    return ""
                }

                return line
            }

        normalized = normalizedLines.joined(separator: "\n")

        // Convert common inline Markdown patterns to plain text.
        normalized = normalized.replacingOccurrences(of: "**", with: "")
        normalized = normalized.replacingOccurrences(of: "__", with: "")
        normalized = normalized.replacingOccurrences(of: "~~", with: "")
        normalized = normalized.replacingRegexMatches(of: #"`([^`\n]+)`"#, with: "$1")
        normalized = normalized.replacingRegexMatches(of: #"\*([^*\n]+)\*"#, with: "$1")
        normalized = normalized.replacingRegexMatches(of: #"_([^_\n]+)_"#, with: "$1")
        normalized = normalized.replacingRegexMatches(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)")

        // Keep spacing readable after cleanup.
        normalized = normalized.replacingRegexMatches(of: #"\n{3,}"#, with: "\n\n")
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
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

        let cleanedText = normalizeTelegramText(text)
        let finalText = cleanedText.isEmpty ? text : cleanedText

        let body = TelegramSendMessageRequest(
            chatId: chatId,
            text: finalText,
            parseMode: nil
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

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
            let safeCaption = normalizeTelegramText(caption)
            if !safeCaption.isEmpty {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(safeCaption)\r\n".data(using: .utf8)!)
            }
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
            let safeCaption = normalizeTelegramText(caption)
            if !safeCaption.isEmpty {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(safeCaption)\r\n".data(using: .utf8)!)
            }
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

private extension String {
    func replacingRegexMatches(of pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: replacement)
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
