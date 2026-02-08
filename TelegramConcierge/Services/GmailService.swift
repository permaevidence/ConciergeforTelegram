import Foundation
import Network
import AppKit

/// Gmail API service with OAuth 2.0 authentication
/// Uses Desktop app OAuth flow with localhost redirect for Xcode testing
actor GmailService {
    static let shared = GmailService()
    
    // MARK: - Configuration
    
    private var clientId: String?
    private var clientSecret: String?
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    
    // MARK: - Background Fetch State
    
    private var cachedEmails: [GmailMessage] = []
    private var lastFetchTime: Date?
    private var backgroundFetchTask: Task<Void, Never>?
    private var isBackgroundFetchRunning = false
    private var knownEmailIds: Set<String> = []
    private var newEmailHandler: (([GmailMessage]) async -> Void)?
    
    /// Background fetch interval (5 minutes)
    private let backgroundFetchInterval: TimeInterval = 300
    
    private let gmailCacheURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("gmailCache.json")
    }()
    
    private let gmailFetchTimeURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        return folder.appendingPathComponent("gmailFetchTime.txt")
    }()
    
    private let gmailKnownIdsURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        return folder.appendingPathComponent("gmailKnownIds.json")
    }()
    
    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"
    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let scopes = "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar"
    private let redirectPort: UInt16 = 8080
    private let redirectURI = "http://localhost:8080/oauth/callback"
    
    private init() {
        loadCredentials()
    }
    
    // MARK: - Public Configuration
    
    var isConfigured: Bool {
        clientId != nil && clientSecret != nil && !clientId!.isEmpty && !clientSecret!.isEmpty
    }
    
    var isAuthenticated: Bool {
        accessToken != nil && refreshToken != nil
    }
    
    func configure(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        saveCredentials()
    }
    
    // MARK: - OAuth Authentication
    
    /// Start OAuth flow - opens browser and waits for callback
    func authenticate() async throws -> Bool {
        guard let clientId = clientId else {
            throw GmailError.notConfigured
        }
        
        // Build authorization URL
        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        
        guard let authorizationURL = components.url else {
            throw GmailError.invalidConfiguration
        }
        
        // Open browser for user consent
        print("[GmailService] Opening browser for OAuth: \(authorizationURL)")
        
        // Start local HTTP server to capture callback
        let code = try await startOAuthCallbackServerAsync(authorizationURL: authorizationURL)
        
        // Exchange code for tokens
        try await exchangeCodeForTokens(code: code)
        
        print("[GmailService] OAuth authentication successful")
        return true
    }
    
    /// Keep strong reference to listener during OAuth flow
    private var activeListener: NWListener?
    
    private func startOAuthCallbackServerAsync(authorizationURL: URL) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: redirectPort)!)
                self.activeListener = listener // Keep strong reference
                
                var continuationResumed = false
                
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        print("[GmailService] OAuth callback server ready on port \(self?.redirectPort ?? 0)")
                        // Open browser only after server is ready
                        DispatchQueue.main.async {
                            NSWorkspace.shared.open(authorizationURL)
                        }
                    case .failed(let error):
                        print("[GmailService] Listener failed: \(error)")
                        if !continuationResumed {
                            continuationResumed = true
                            continuation.resume(throwing: GmailError.serverFailed)
                        }
                    case .cancelled:
                        print("[GmailService] Listener cancelled")
                    default:
                        break
                    }
                }
                
                listener.newConnectionHandler = { [weak self] connection in
                    print("[GmailService] Received connection")
                    connection.start(queue: .global())
                    
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                        if let error = error {
                            print("[GmailService] Connection receive error: \(error)")
                        }
                        
                        guard !continuationResumed else { return }
                        
                        guard let data = data, let request = String(data: data, encoding: .utf8) else {
                            print("[GmailService] Failed to read request data")
                            continuationResumed = true
                            self?.cleanupListener()
                            continuation.resume(throwing: GmailError.invalidCallback)
                            return
                        }
                        
                        print("[GmailService] Received request: \(request.prefix(200))...")
                        
                        // Parse authorization code from: GET /oauth/callback?code=XXX&scope=... HTTP/1.1
                        if let codeRange = request.range(of: "code="),
                           let endRange = request.range(of: "&", range: codeRange.upperBound..<request.endIndex) 
                                        ?? request.range(of: " ", range: codeRange.upperBound..<request.endIndex) {
                            let code = String(request[codeRange.upperBound..<endRange.lowerBound])
                            
                            // URL decode the code
                            let decodedCode = code.removingPercentEncoding ?? code
                            
                            print("[GmailService] Extracted auth code: \(decodedCode.prefix(20))...")
                            
                            // Send success response
                            let response = """
                            HTTP/1.1 200 OK\r
                            Content-Type: text/html; charset=utf-8\r
                            Connection: close\r
                            \r
                            <html><head><title>Success</title></head><body style="font-family: -apple-system, sans-serif; text-align: center; padding: 50px;">
                            <h1 style="color: #34C759;">✓ Authentication Successful!</h1>
                            <p>You can close this window and return to the app.</p>
                            </body></html>
                            """
                            
                            connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                                connection.cancel()
                            }))
                            
                            continuationResumed = true
                            self?.cleanupListener()
                            continuation.resume(returning: decodedCode)
                            
                        } else if request.contains("error=") {
                            print("[GmailService] Auth error in callback")
                            let response = """
                            HTTP/1.1 200 OK\r
                            Content-Type: text/html\r
                            Connection: close\r
                            \r
                            <html><body><h1>Authentication Failed</h1><p>Please try again.</p></body></html>
                            """
                            connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                                connection.cancel()
                            }))
                            
                            continuationResumed = true
                            self?.cleanupListener()
                            continuation.resume(throwing: GmailError.authDenied)
                            
                        } else {
                            print("[GmailService] Could not parse auth code from request")
                            continuationResumed = true
                            self?.cleanupListener()
                            continuation.resume(throwing: GmailError.invalidCallback)
                        }
                    }
                }
                
                listener.start(queue: .global())
                print("[GmailService] Starting OAuth callback listener...")
                
            } catch {
                print("[GmailService] Failed to create listener: \(error)")
                continuation.resume(throwing: GmailError.serverFailed)
            }
        }
    }
    
    private func cleanupListener() {
        activeListener?.cancel()
        activeListener = nil
    }
    
    private func exchangeCodeForTokens(code: String) async throws {
        guard let clientId = clientId, let clientSecret = clientSecret else {
            throw GmailError.notConfigured
        }
        
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
         .joined(separator: "&")
        
        request.httpBody = body.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("[GmailService] Token exchange failed: \(String(data: data, encoding: .utf8) ?? "unknown")")
            throw GmailError.tokenExchangeFailed
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        
        self.accessToken = tokenResponse.accessToken
        self.refreshToken = tokenResponse.refreshToken ?? self.refreshToken // Keep existing if not returned
        self.tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn - 60)) // 1 min buffer
        
        saveCredentials()
        print("[GmailService] Tokens saved, expires in \(tokenResponse.expiresIn)s")
    }
    
    private func refreshAccessToken() async throws {
        guard let clientId = clientId, let clientSecret = clientSecret, let refreshToken = refreshToken else {
            throw GmailError.notConfigured
        }
        
        print("[GmailService] Refreshing access token...")
        
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
         .joined(separator: "&")
        
        request.httpBody = body.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("[GmailService] Token refresh failed: \(String(data: data, encoding: .utf8) ?? "unknown")")
            throw GmailError.tokenRefreshFailed
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        
        self.accessToken = tokenResponse.accessToken
        self.tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn - 60))
        
        saveCredentials()
        print("[GmailService] Access token refreshed")
    }
    
    /// Ensure we have a valid access token, refreshing if needed
    private func ensureValidToken() async throws -> String {
        if let expiry = tokenExpiry, Date() >= expiry {
            try await refreshAccessToken()
        }
        
        guard let token = accessToken else {
            throw GmailError.notAuthenticated
        }
        
        return token
    }
    
    // MARK: - Gmail API Operations
    
    /// Query emails using Gmail search syntax
    /// Examples: "from:john", "after:2026/01/01", "has:attachment", "is:unread"
    func queryEmails(query: String? = nil, limit: Int = 10) async throws -> [GmailMessage] {
        let token = try await ensureValidToken()
        
        var urlComponents = URLComponents(string: "\(baseURL)/messages")!
        var queryItems = [URLQueryItem(name: "maxResults", value: String(min(limit, 100)))]
        if let query = query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        urlComponents.queryItems = queryItems
        
        var request = URLRequest(url: urlComponents.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GmailError.apiFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        
        let listResponse = try JSONDecoder().decode(MessageListResponse.self, from: data)
        
        guard let messageIds = listResponse.messages else {
            return []
        }
        
        // Fetch full message details for each
        var messages: [GmailMessage] = []
        for messageRef in messageIds.prefix(limit) {
            if let fullMessage = try? await getMessage(id: messageRef.id) {
                messages.append(fullMessage)
            }
        }
        
        return messages
    }
    
    /// Get a single message by ID with full metadata
    private func getMessage(id: String) async throws -> GmailMessage {
        let token = try await ensureValidToken()
        
        var urlComponents = URLComponents(string: "\(baseURL)/messages/\(id)")!
        urlComponents.queryItems = [URLQueryItem(name: "format", value: "full")]
        
        var request = URLRequest(url: urlComponents.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GmailError.apiFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        
        return try JSONDecoder().decode(GmailMessage.self, from: data)
    }
    
    /// Get a full email thread
    func getThread(id: String) async throws -> GmailThread {
        let token = try await ensureValidToken()
        
        var urlComponents = URLComponents(string: "\(baseURL)/threads/\(id)")!
        urlComponents.queryItems = [URLQueryItem(name: "format", value: "full")]
        
        var request = URLRequest(url: urlComponents.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GmailError.apiFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        
        return try JSONDecoder().decode(GmailThread.self, from: data)
    }
    
    /// Send an email (new or reply)
    /// If threadId is provided, the email is sent as a reply in that thread
    func sendEmail(
        to: String,
        subject: String,
        body: String,
        threadId: String? = nil,
        inReplyTo: String? = nil,
        cc: [String] = [],
        bcc: [String] = [],
        attachments: [(data: Data, name: String, mimeType: String)] = []
    ) async throws -> Bool {
        let token = try await ensureValidToken()
        
        // Get sender email from profile
        let profile = try await getProfile()
        let from = profile.emailAddress
        
        var seen: Set<String> = []
        var normalizedCC: [String] = []
        var normalizedBCC: [String] = []
        
        func normalizeAddress(_ address: String) -> String {
            address.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        func insertUnique(_ address: String) -> Bool {
            let normalized = normalizeAddress(address)
            guard !normalized.isEmpty else { return false }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { return false }
            return true
        }
        
        _ = insertUnique(to)
        for recipient in cc where insertUnique(recipient) {
            normalizedCC.append(normalizeAddress(recipient))
        }
        for recipient in bcc where insertUnique(recipient) {
            normalizedBCC.append(normalizeAddress(recipient))
        }
        
        // Build RFC 2822 message
        var rawMessage = """
        From: \(from)
        To: \(to)
        Subject: \(subject)
        """
        if !normalizedCC.isEmpty {
            rawMessage += "\nCc: \(normalizedCC.joined(separator: ", "))"
        }
        if !normalizedBCC.isEmpty {
            rawMessage += "\nBcc: \(normalizedBCC.joined(separator: ", "))"
        }
        
        if let replyTo = inReplyTo {
            rawMessage += "\nIn-Reply-To: \(replyTo)"
            rawMessage += "\nReferences: \(replyTo)"
        }
        
        if !attachments.isEmpty {
            // MIME multipart message with multiple attachments
            let boundary = "boundary_\(UUID().uuidString)"
            
            rawMessage += "\nMIME-Version: 1.0"
            rawMessage += "\nContent-Type: multipart/mixed; boundary=\"\(boundary)\""
            rawMessage += "\n\n--\(boundary)"
            rawMessage += "\nContent-Type: text/plain; charset=\"UTF-8\""
            rawMessage += "\n\n\(body)"
            
            // Add each attachment as a separate MIME part
            for attachment in attachments {
                rawMessage += "\n\n--\(boundary)"
                rawMessage += "\nContent-Type: \(attachment.mimeType); name=\"\(attachment.name)\""
                rawMessage += "\nContent-Disposition: attachment; filename=\"\(attachment.name)\""
                rawMessage += "\nContent-Transfer-Encoding: base64"
                rawMessage += "\n\n\(attachment.data.base64EncodedString(options: .lineLength76Characters))"
            }
            
            rawMessage += "\n--\(boundary)--"
        } else {
            rawMessage += "\nContent-Type: text/plain; charset=\"UTF-8\""
            rawMessage += "\n\n\(body)"
        }
        
        // Base64url encode the message
        let base64Message = rawMessage.data(using: .utf8)!
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        // Build request
        var request = URLRequest(url: URL(string: "\(baseURL)/messages/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var requestBody: [String: Any] = ["raw": base64Message]
        if let threadId = threadId {
            requestBody["threadId"] = threadId
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("[GmailService] Send failed: \(String(data: data, encoding: .utf8) ?? "unknown")")
            throw GmailError.sendFailed
        }
        
        print("[GmailService] Email sent successfully")
        return true
    }
    
    /// Forward an email with all attachments
    func forwardEmail(
        to: String,
        messageId: String,
        comment: String?
    ) async throws -> Bool {
        // Get the original message
        let original = try await getMessage(id: messageId)
        
        let originalFrom = original.getHeader("From") ?? "Unknown"
        let originalDate = original.getHeader("Date") ?? ""
        let originalSubject = original.getHeader("Subject") ?? ""
        let originalBody = original.getPlainTextBody()
        
        let forwardSubject = originalSubject.hasPrefix("Fwd:") ? originalSubject : "Fwd: \(originalSubject)"
        
        var forwardBody = ""
        if let comment = comment, !comment.isEmpty {
            forwardBody = "\(comment)\n\n"
        }
        forwardBody += """
        ---------- Forwarded message ---------
        From: \(originalFrom)
        Date: \(originalDate)
        Subject: \(originalSubject)
        
        \(originalBody)
        """
        
        // Get and download ALL attachments from original
        let attachmentParts = original.payload?.getAttachmentParts() ?? []
        var attachments: [(data: Data, name: String, mimeType: String)] = []
        
        for part in attachmentParts {
            guard let attachmentId = part.body?.attachmentId else { continue }
            let downloaded = try await downloadAttachment(messageId: messageId, attachmentId: attachmentId)
            attachments.append((
                data: downloaded.data,
                name: part.filename ?? "attachment",
                mimeType: part.mimeType ?? "application/octet-stream"
            ))
        }
        
        return try await sendEmail(
            to: to,
            subject: forwardSubject,
            body: forwardBody,
            attachments: attachments
        )
    }
    
    /// Download an attachment
    func downloadAttachment(messageId: String, attachmentId: String) async throws -> (data: Data, filename: String, mimeType: String) {
        let token = try await ensureValidToken()
        
        // URL-encode the attachment ID (it may contain special characters)
        guard let encodedAttachmentId = attachmentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw GmailError.invalidAttachment
        }
        
        let url = URL(string: "\(baseURL)/messages/\(messageId)/attachments/\(encodedAttachmentId)")!
        print("[GmailService] Downloading attachment from: \(url)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GmailError.apiFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        
        let attachmentResponse = try JSONDecoder().decode(AttachmentResponse.self, from: data)
        
        // Decode base64url data
        var base64 = attachmentResponse.data
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        
        guard let attachmentData = Data(base64Encoded: base64) else {
            throw GmailError.invalidAttachment
        }
        
        // Get filename from message if needed
        let message = try await getMessage(id: messageId)
        let parts = message.payload?.getAttachmentParts() ?? []
        let matchingPart = parts.first { $0.body?.attachmentId == attachmentId }
        
        return (
            data: attachmentData,
            filename: matchingPart?.filename ?? "attachment",
            mimeType: matchingPart?.mimeType ?? "application/octet-stream"
        )
    }
    
    /// Get user profile (email address)
    private func getProfile() async throws -> GmailProfile {
        let token = try await ensureValidToken()
        
        let url = URL(string: "\(baseURL)/profile")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GmailError.apiFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        
        return try JSONDecoder().decode(GmailProfile.self, from: data)
    }
    
    /// Get recent emails for system prompt context (uses cache, no blocking fetch)
    func getEmailContextForSystemPrompt() async -> String {
        guard isAuthenticated else { return "" }
        
        // Always use cache - no fetch at prompt time
        if !cachedEmails.isEmpty {
            let ageStr: String
            if let lastFetch = lastFetchTime {
                let ageSeconds = Int(Date().timeIntervalSince(lastFetch))
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                ageStr = "age: \(ageSeconds)s, fetched at \(formatter.string(from: lastFetch))"
                print("[GmailService] Context: Using cached emails (\(ageStr))")
            } else {
                ageStr = "fetch time unknown"
            }
            return formatEmailsForContext(cachedEmails, fetchTime: lastFetchTime)
        }
        
        // Cache is empty
        return "📧 **Your Inbox**: No cached emails. Use email tools to fetch."
    }
    
    /// Format emails for system prompt injection
    private func formatEmailsForContext(_ emails: [GmailMessage], fetchTime: Date?) -> String {
        guard !emails.isEmpty else {
            return "📧 **Your Inbox**: No recent emails."
        }
        
        // Format the fetch timestamp - use ONLY relative time
        let fetchTimeStr: String
        if let fetchTime = fetchTime {
            let ageSeconds = Int(Date().timeIntervalSince(fetchTime))
            if ageSeconds < 5 {
                fetchTimeStr = "just now"
            } else if ageSeconds < 60 {
                fetchTimeStr = "\(ageSeconds) seconds ago"
            } else if ageSeconds < 3600 {
                let mins = ageSeconds / 60
                fetchTimeStr = "\(mins) minute\(mins == 1 ? "" : "s") ago"
            } else {
                let hours = ageSeconds / 3600
                fetchTimeStr = "\(hours) hour\(hours == 1 ? "" : "s") ago"
            }
        } else {
            fetchTimeStr = "unknown"
        }
        
        var lines: [String] = ["📧 **Your Inbox** (last \(emails.count) emails, fetched \(fetchTimeStr)):"]
        
        for email in emails {
            let from = email.getHeader("From") ?? "Unknown"
            let subject = email.getHeader("Subject") ?? "(No subject)"
            var line = "• **\(subject)** from \(from) [ID: \(email.id)]"
            
            // Add preview if available
            if let snippet = email.snippet, !snippet.isEmpty {
                let preview = snippet.prefix(100)
                line += "\n  └ \(preview)..."
            }
            
            // Note attachments
            let attachments = email.payload?.getAttachmentParts() ?? []
            if !attachments.isEmpty {
                let attachNames = attachments.compactMap { $0.filename }.joined(separator: ", ")
                line += "\n  📎 \(attachments.count) attachment(s): \(attachNames)"
            }
            
            lines.append(line)
        }
        
        lines.append("")
        lines.append("Use email tools for more details or actions.")
        
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Background Email Fetch
    
    /// Set a handler to be notified when new emails arrive
    func setNewEmailHandler(_ handler: @escaping ([GmailMessage]) async -> Void) {
        self.newEmailHandler = handler
    }
    
    /// Start the background email fetch loop (every 5 minutes)
    func startBackgroundFetch() {
        guard !isBackgroundFetchRunning else {
            print("[GmailService] Background: Already running")
            return
        }
        
        guard isAuthenticated else {
            print("[GmailService] Background: Not authenticated, cannot start")
            return
        }
        
        // Load cached emails from disk on startup
        loadCacheFromDisk()
        loadKnownIdsFromDisk()
        
        isBackgroundFetchRunning = true
        
        backgroundFetchTask = Task.detached { [weak self] in
            await self?.runBackgroundFetchLoop()
        }
        
        print("[GmailService] Background: Fetch loop started (every 5 min)")
    }
    
    /// Stop the background fetch loop
    func stopBackgroundFetch() {
        isBackgroundFetchRunning = false
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
        print("[GmailService] Background: Fetch loop stopped")
    }
    
    /// Main background fetch loop
    private func runBackgroundFetchLoop() async {
        // Fetch immediately on start
        await performBackgroundFetch()
        
        // Then fetch every 5 minutes
        while isBackgroundFetchRunning && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(backgroundFetchInterval * 1_000_000_000))
                await performBackgroundFetch()
            } catch {
                // Task was cancelled
                break
            }
        }
    }
    
    /// Perform a single background fetch
    private func performBackgroundFetch() async {
        do {
            let emails = try await queryEmails(query: "in:inbox", limit: 10)
            
            // Detect new emails by comparing IDs
            let currentIds = Set(emails.map { $0.id })
            let newIds = currentIds.subtracting(knownEmailIds)
            
            // Update cache
            cachedEmails = emails
            lastFetchTime = Date()
            saveCacheToDisk()
            
            // Update known IDs and persist
            knownEmailIds = currentIds
            saveKnownIdsToDisk()
            
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            print("[GmailService] Background: Fetch complete at \(formatter.string(from: Date())) (\(emails.count) emails, \(newIds.count) new)")
            
            // Notify about new emails in a detached task (non-blocking)
            if !newIds.isEmpty, let handler = newEmailHandler {
                let newEmails = emails.filter { newIds.contains($0.id) }
                Task.detached {
                    await handler(newEmails)
                }
            }
        } catch {
            print("[GmailService] Background: Fetch failed - \(error.localizedDescription)")
        }
    }
    
    // MARK: - Gmail Cache Persistence
    
    private func loadCacheFromDisk() {
        // Load cached emails
        if FileManager.default.fileExists(atPath: gmailCacheURL.path) {
            do {
                let data = try Data(contentsOf: gmailCacheURL)
                cachedEmails = try JSONDecoder().decode([GmailMessage].self, from: data)
                print("[GmailService] Loaded \(cachedEmails.count) emails from disk cache")
            } catch {
                print("[GmailService] Failed to load email cache: \(error)")
            }
        }
        
        // Load last fetch time
        if FileManager.default.fileExists(atPath: gmailFetchTimeURL.path) {
            do {
                let timeStr = try String(contentsOf: gmailFetchTimeURL, encoding: .utf8)
                if let timestamp = Double(timeStr) {
                    lastFetchTime = Date(timeIntervalSince1970: timestamp)
                    let age = Int(Date().timeIntervalSince(lastFetchTime!))
                    print("[GmailService] Loaded fetch time from disk (age: \(age)s)")
                }
            } catch {
                print("[GmailService] Failed to load fetch time: \(error)")
            }
        }
        
        // If we loaded emails but have no fetch time, treat cache as fresh
        if !cachedEmails.isEmpty && lastFetchTime == nil {
            lastFetchTime = Date()
            print("[GmailService] No fetch time found, treating cache as fresh")
        }
    }
    
    private func saveCacheToDisk() {
        do {
            // Save emails
            let data = try JSONEncoder().encode(cachedEmails)
            try data.write(to: gmailCacheURL)
            
            // Save fetch time
            if let fetchTime = lastFetchTime {
                let timeStr = String(fetchTime.timeIntervalSince1970)
                try timeStr.write(to: gmailFetchTimeURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("[GmailService] Failed to save email cache: \(error)")
        }
    }
    
    private func loadKnownIdsFromDisk() {
        guard FileManager.default.fileExists(atPath: gmailKnownIdsURL.path) else { return }
        do {
            let data = try Data(contentsOf: gmailKnownIdsURL)
            let ids = try JSONDecoder().decode([String].self, from: data)
            knownEmailIds = Set(ids)
            print("[GmailService] Loaded \(knownEmailIds.count) known IDs from disk")
        } catch {
            print("[GmailService] Failed to load known IDs: \(error)")
        }
    }
    
    private func saveKnownIdsToDisk() {
        do {
            let data = try JSONEncoder().encode(Array(knownEmailIds))
            try data.write(to: gmailKnownIdsURL)
        } catch {
            print("[GmailService] Failed to save known IDs: \(error)")
        }
    }
    
    // MARK: - Persistence
    
    private func loadCredentials() {
        clientId = KeychainHelper.load(key: KeychainHelper.gmailClientIdKey)
        clientSecret = KeychainHelper.load(key: KeychainHelper.gmailClientSecretKey)
        accessToken = KeychainHelper.load(key: KeychainHelper.gmailAccessTokenKey)
        refreshToken = KeychainHelper.load(key: KeychainHelper.gmailRefreshTokenKey)
        
        if let expiryString = KeychainHelper.load(key: KeychainHelper.gmailTokenExpiryKey),
           let expiryInterval = TimeInterval(expiryString) {
            tokenExpiry = Date(timeIntervalSince1970: expiryInterval)
        }
    }
    
    private func saveCredentials() {
        if let clientId = clientId {
            try? KeychainHelper.save(key: KeychainHelper.gmailClientIdKey, value: clientId)
        }
        if let clientSecret = clientSecret {
            try? KeychainHelper.save(key: KeychainHelper.gmailClientSecretKey, value: clientSecret)
        }
        if let accessToken = accessToken {
            try? KeychainHelper.save(key: KeychainHelper.gmailAccessTokenKey, value: accessToken)
        }
        if let refreshToken = refreshToken {
            try? KeychainHelper.save(key: KeychainHelper.gmailRefreshTokenKey, value: refreshToken)
        }
        if let tokenExpiry = tokenExpiry {
            try? KeychainHelper.save(key: KeychainHelper.gmailTokenExpiryKey, value: String(tokenExpiry.timeIntervalSince1970))
        }
    }
    
    func clearCredentials() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        try? KeychainHelper.delete(key: KeychainHelper.gmailAccessTokenKey)
        try? KeychainHelper.delete(key: KeychainHelper.gmailRefreshTokenKey)
        try? KeychainHelper.delete(key: KeychainHelper.gmailTokenExpiryKey)
    }
}

// MARK: - Data Models

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

private struct MessageListResponse: Decodable {
    let messages: [MessageRef]?
    let nextPageToken: String?
}

private struct MessageRef: Decodable {
    let id: String
    let threadId: String
}

private struct AttachmentResponse: Decodable {
    let size: Int
    let data: String
}

struct GmailProfile: Decodable {
    let emailAddress: String
    let messagesTotal: Int?
    let threadsTotal: Int?
}

struct GmailMessage: Codable {
    let id: String
    let threadId: String
    let labelIds: [String]?
    let snippet: String?
    let payload: GmailPayload?
    let internalDate: String?
    
    func getHeader(_ name: String) -> String? {
        payload?.headers?.first { $0.name.lowercased() == name.lowercased() }?.value
    }
    
    func getPlainTextBody() -> String {
        // Try to get plain text from payload
        if let payload = payload {
            return payload.getPlainTextBody()
        }
        return snippet ?? ""
    }
}

struct GmailPayload: Codable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPayload]?
    
    func getPlainTextBody() -> String {
        // Check this part
        if mimeType == "text/plain", let body = body, let data = body.data {
            return decodeBase64Url(data)
        }
        
        // Check nested parts
        if let parts = parts {
            for part in parts {
                let text = part.getPlainTextBody()
                if !text.isEmpty {
                    return text
                }
            }
        }
        
        return ""
    }
    
    func getAttachmentParts() -> [GmailPayload] {
        var attachments: [GmailPayload] = []
        
        if let filename = filename, !filename.isEmpty, body?.attachmentId != nil {
            attachments.append(self)
        }
        
        if let parts = parts {
            for part in parts {
                attachments.append(contentsOf: part.getAttachmentParts())
            }
        }
        
        return attachments
    }
    
    private func decodeBase64Url(_ encoded: String) -> String {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        
        guard let data = Data(base64Encoded: base64),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        
        return string
    }
}

struct GmailHeader: Codable {
    let name: String
    let value: String
}

struct GmailBody: Codable {
    let size: Int
    let data: String?
    let attachmentId: String?
}

struct GmailThread: Decodable {
    let id: String
    let historyId: String?
    let messages: [GmailMessage]?
}

// MARK: - Errors

enum GmailError: Error, LocalizedError {
    case notConfigured
    case invalidConfiguration
    case serverFailed
    case invalidCallback
    case authDenied
    case tokenExchangeFailed
    case tokenRefreshFailed
    case notAuthenticated
    case apiFailed(String)
    case sendFailed
    case invalidAttachment
    
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Gmail API not configured"
        case .invalidConfiguration: return "Invalid Gmail configuration"
        case .serverFailed: return "OAuth callback server failed to start"
        case .invalidCallback: return "Invalid OAuth callback"
        case .authDenied: return "Authentication denied by user"
        case .tokenExchangeFailed: return "Failed to exchange authorization code"
        case .tokenRefreshFailed: return "Failed to refresh access token"
        case .notAuthenticated: return "Not authenticated with Gmail"
        case .apiFailed(let msg): return "Gmail API error: \(msg)"
        case .sendFailed: return "Failed to send email"
        case .invalidAttachment: return "Invalid attachment data"
        }
    }
}
