import Foundation

// MARK: - HTTP Helpers

func httpJSONPost<T: Encodable>(url: URL, body: T, headers: [String: String], timeout: TimeInterval) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = timeout
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    request.httpBody = try JSONEncoder().encode(body)
    
    let (data, response) = try await URLSession.shared.data(for: request)
    try HTTPError.throwIfBad(response, data: data)
    return data
}

// MARK: - HTTP Error

enum HTTPError: LocalizedError {
    case badStatus(Int, String?)
    
    static func throwIfBad(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data.prefix(500), encoding: .utf8)
            throw HTTPError.badStatus(http.statusCode, body)
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body):
            return "HTTP \(code): \(body ?? "No body")"
        }
    }
}

// MARK: - JSON Extraction

/// Extract the first JSON object from a string that may contain other text
func extractFirstJSONObjectData(from text: String) -> Data? {
    guard let start = text.firstIndex(of: "{") else { return nil }
    
    var depth = 0
    var inString = false
    var escape = false
    var endIndex: String.Index?
    
    for i in text.indices[start...] {
        let char = text[i]
        
        if escape {
            escape = false
            continue
        }
        
        if char == "\\" && inString {
            escape = true
            continue
        }
        
        if char == "\"" {
            inString = !inString
            continue
        }
        
        if inString { continue }
        
        if char == "{" {
            depth += 1
        } else if char == "}" {
            depth -= 1
            if depth == 0 {
                endIndex = text.index(after: i)
                break
            }
        }
    }
    
    guard let end = endIndex else { return nil }
    let jsonString = String(text[start..<end])
    return jsonString.data(using: .utf8)
}

// MARK: - Time Helpers

func nowStamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm (EEEE)"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: Date())
}

// MARK: - String Extensions

extension String {
    func prefixing(_ maxLength: Int) -> String {
        if self.count <= maxLength { return self }
        return String(self.prefix(maxLength))
    }
}

// MARK: - Phone Number Autolinking

func autolinkPhoneNumbers(_ text: String) -> String {
    // Match phone patterns and wrap in markdown links
    // This is a simplified version - the original may have been more complex
    let pattern = #"(?<!\[)(\+?\d[\d\s\-\.]{7,}\d)(?!\])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    
    let range = NSRange(text.startIndex..., in: text)
    var result = text
    
    let matches = regex.matches(in: text, range: range).reversed()
    for match in matches {
        guard let phoneRange = Range(match.range(at: 1), in: result) else { continue }
        let phone = String(result[phoneRange])
        let cleaned = phone.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        result.replaceSubrange(phoneRange, with: "[\(phone)](tel:\(cleaned))")
    }
    
    return result
}
