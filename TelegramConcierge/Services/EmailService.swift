import Foundation
import Network

// MARK: - Email Models

/// Represents an email attachment with metadata for LLM visibility
struct EmailAttachment: Codable {
    let partId: String       // MIME part identifier (e.g., "1.2") for downloading
    let filename: String     // Original filename
    let mimeType: String     // e.g., "application/pdf", "image/jpeg"
    let size: Int            // Size in bytes
    let encoding: String     // e.g., "base64", "quoted-printable"
}

struct EmailMessage: Codable {
    let id: String
    let messageId: String  // RFC 5322 Message-ID header for threading
    let inReplyTo: String?  // Message-ID of parent email (for thread awareness)
    let references: String?  // Space-separated chain of ancestor Message-IDs
    let from: String
    let subject: String
    let date: String
    let bodyPreview: String
    let attachments: [EmailAttachment]  // Attachment metadata for LLM visibility
}

struct EmailConfig {
    let imapHost: String
    let imapPort: Int
    let smtpHost: String
    let smtpPort: Int
    let username: String
    let password: String
    let displayName: String
}

// MARK: - Email Service

actor EmailService {
    private var config: EmailConfig?
    
    static let shared = EmailService()
    
    // MARK: - Configuration
    
    func configure(
        imapHost: String,
        imapPort: Int,
        smtpHost: String,
        smtpPort: Int,
        username: String,
        password: String,
        displayName: String
    ) {
        self.config = EmailConfig(
            imapHost: imapHost,
            imapPort: imapPort,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            username: username,
            password: password,
            displayName: displayName
        )
    }
    
    var isConfigured: Bool {
        config != nil
    }
    
    // MARK: - Email Context Cache
    
    private var cachedEmails: [EmailMessage] = []
    private var lastFetchTime: Date?
    private var backgroundFetchTask: Task<Void, Never>?
    private var isBackgroundFetchRunning = false
    
    /// Known email UIDs (for detecting new arrivals)
    private var knownEmailUIDs: Set<String> = []
    
    /// Notification handler for new emails (runs in detached task)
    private var newEmailHandler: (([EmailMessage]) async -> Void)?
    
    /// Background fetch interval (5 minutes)
    private let backgroundFetchInterval: TimeInterval = 300
    
    private let emailCacheURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("emailCache.json")
    }()
    
    private let fetchTimeURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        return folder.appendingPathComponent("emailFetchTime.txt")
    }()
    
    private let knownUIDsURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        return folder.appendingPathComponent("knownEmailUIDs.json")
    }()
    
    // MARK: - Email Context for System Prompt (Always Uses Cache)
    
    /// Get formatted email context for LLM system prompt.
    /// Always returns cached emails immediately - no blocking fetch.
    /// The LLM can use read_emails tool if it determines cache is stale.
    func getEmailContextForSystemPrompt() async -> String {
        guard isConfigured else {
            return ""
        }
        
        // Always use cache - no fetch at prompt time
        if !cachedEmails.isEmpty {
            let ageStr: String
            if let lastFetch = lastFetchTime {
                let ageSeconds = Int(Date().timeIntervalSince(lastFetch))
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                ageStr = "age: \(ageSeconds)s, fetched at \(formatter.string(from: lastFetch))"
                print("[EmailService] Context: Using cached emails (\(ageStr))")
            } else {
                ageStr = "fetch time unknown"
            }
            return formatEmailsForContext(cachedEmails, fetchTime: lastFetchTime)
        }
        
        // Cache is empty
        return "📧 **Your Inbox**: No cached emails. Use `read_emails` tool to fetch."
    }
    
    /// Format emails for system prompt injection
    private func formatEmailsForContext(_ emails: [EmailMessage], fetchTime: Date?) -> String {
        guard !emails.isEmpty else {
            return "📧 **Your Inbox**: No recent emails."
        }
        
        // Format the fetch timestamp - use ONLY relative time to avoid confusing LLM about current time
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
        
        var lines: [String] = ["📧 **Your Inbox** (last \(emails.count) emails, fetched \(fetchTimeStr)):", ""]
        
        for email in emails {
            var line = "• **\(email.subject)** from \(email.from)"
            if !email.date.isEmpty {
                line += " (\(email.date))"
            }
            line += " [UID: \(email.id)]"
            
            // Add preview if available (truncated)
            if !email.bodyPreview.isEmpty {
                let preview = email.bodyPreview
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(100)
                line += "\n  └ \(preview)..."
            }
            
            // Note attachments
            if !email.attachments.isEmpty {
                let attachNames = email.attachments.map { $0.filename }.joined(separator: ", ")
                line += "\n  📎 \(email.attachments.count) attachment(s): \(attachNames)"
            }
            
            lines.append(line)
        }
        
        lines.append("")
        lines.append("Use `read_emails`, `search_emails`, or `reply_email` tools for more details or actions.")
        
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Disk Cache Persistence
    
    private func loadCacheFromDisk() {
        // Load cached emails
        if FileManager.default.fileExists(atPath: emailCacheURL.path) {
            do {
                let data = try Data(contentsOf: emailCacheURL)
                cachedEmails = try JSONDecoder().decode([EmailMessage].self, from: data)
                print("[EmailService] Loaded \(cachedEmails.count) emails from disk cache")
            } catch {
                print("[EmailService] Failed to load email cache: \(error)")
            }
        }
        
        // Load last fetch time
        if FileManager.default.fileExists(atPath: fetchTimeURL.path) {
            do {
                let timeStr = try String(contentsOf: fetchTimeURL, encoding: .utf8)
                if let timestamp = Double(timeStr) {
                    lastFetchTime = Date(timeIntervalSince1970: timestamp)
                    let age = Int(Date().timeIntervalSince(lastFetchTime!))
                    print("[EmailService] Loaded fetch time from disk (age: \(age)s)")
                }
            } catch {
                print("[EmailService] Failed to load fetch time: \(error)")
            }
        }
        
        // If we loaded emails but have no fetch time (upgrade scenario), treat cache as fresh
        if !cachedEmails.isEmpty && lastFetchTime == nil {
            lastFetchTime = Date()
            print("[EmailService] No fetch time found, treating cache as fresh")
        }
    }
    
    private func saveCacheToDisK() {
        do {
            // Save emails
            let data = try JSONEncoder().encode(cachedEmails)
            try data.write(to: emailCacheURL)
            
            // Save fetch time
            if let fetchTime = lastFetchTime {
                let timeStr = String(fetchTime.timeIntervalSince1970)
                try timeStr.write(to: fetchTimeURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("[EmailService] Failed to save email cache: \(error)")
        }
    }
    
    // MARK: - Background Email Fetch (Simple 5-minute polling)
    
    /// Set a handler to be notified when new emails arrive.
    /// The handler runs in a detached task to avoid blocking.
    func setNewEmailHandler(_ handler: @escaping ([EmailMessage]) async -> Void) {
        self.newEmailHandler = handler
    }
    
    /// Start the background email fetch loop.
    /// Fetches latest 10 emails every 5 minutes and updates the cache.
    func startBackgroundFetch() {
        guard !isBackgroundFetchRunning else {
            print("[EmailService] Background: Already running")
            return
        }
        
        // Load cached emails from disk on startup
        loadCacheFromDisk()
        loadKnownUIDsFromDisk()
        
        isBackgroundFetchRunning = true
        
        backgroundFetchTask = Task.detached { [weak self] in
            await self?.runBackgroundFetchLoop()
        }
        
        print("[EmailService] Background: Fetch loop started (every 5 min)")
    }
    
    /// Stop the background fetch loop
    func stopBackgroundFetch() {
        isBackgroundFetchRunning = false
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
        print("[EmailService] Background: Fetch loop stopped")
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
            let emails = try await fetchEmails(count: 10)
            
            // Detect new emails by comparing UIDs
            let currentUIDs = Set(emails.map { $0.id })
            let newUIDs = currentUIDs.subtracting(knownEmailUIDs)
            
            // Update cache
            cachedEmails = emails
            lastFetchTime = Date()
            saveCacheToDisK()
            
            // Update known UIDs and persist
            knownEmailUIDs = currentUIDs
            saveKnownUIDsToDisk()
            
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            print("[EmailService] Background: Fetch complete at \(formatter.string(from: Date())) (\(emails.count) emails, \(newUIDs.count) new)")
            
            // Notify about new emails in a detached task (non-blocking)
            // Fetch FULL email content for new emails so Gemini gets complete context
            if !newUIDs.isEmpty, let handler = newEmailHandler {
                Task.detached { [weak self, newUIDs] in
                    do {
                        // Fetch full email content (not truncated) for new emails
                        let fullEmails = try await self?.fetchFullEmailsByUID(Array(newUIDs)) ?? []
                        if !fullEmails.isEmpty {
                            print("[EmailService] Background: Fetched \(fullEmails.count) full email(s) for notification")
                            await handler(fullEmails)
                        }
                    } catch {
                        print("[EmailService] Background: Failed to fetch full emails - \(error.localizedDescription)")
                        // Fall back to truncated emails from initial fetch
                        let truncatedNew = emails.filter { newUIDs.contains($0.id) }
                        if !truncatedNew.isEmpty {
                            await handler(truncatedNew)
                        }
                    }
                }
            }
        } catch {
            print("[EmailService] Background: Fetch failed - \(error.localizedDescription)")
        }
    }

    
    // MARK: - Known UIDs Persistence
    
    private func loadKnownUIDsFromDisk() {
        guard FileManager.default.fileExists(atPath: knownUIDsURL.path) else { return }
        do {
            let data = try Data(contentsOf: knownUIDsURL)
            let uids = try JSONDecoder().decode([String].self, from: data)
            knownEmailUIDs = Set(uids)
            print("[EmailService] Loaded \(knownEmailUIDs.count) known UIDs from disk")
        } catch {
            print("[EmailService] Failed to load known UIDs: \(error)")
        }
    }
    
    private func saveKnownUIDsToDisk() {
        do {
            let data = try JSONEncoder().encode(Array(knownEmailUIDs))
            try data.write(to: knownUIDsURL)
        } catch {
            print("[EmailService] Failed to save known UIDs: \(error)")
        }
    }
    
    /// Update the cache with fresh emails (called after tool fetch)
    func updateCache(with emails: [EmailMessage]) {
        cachedEmails = emails
        lastFetchTime = Date()
        saveCacheToDisK()
        print("[EmailService] Cache updated via tool (\(emails.count) emails)")
    }
    
    // MARK: - Fetch Full Emails by UID
    
    /// Fetch emails with full body content (not truncated) by their UIDs.
    /// Used for new email notifications to give Gemini complete context.
    func fetchFullEmailsByUID(_ uids: [String]) async throws -> [EmailMessage] {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        guard !uids.isEmpty else { return [] }
        
        return try await withCheckedThrowingContinuation { continuation in
            var inputStream: InputStream?
            var outputStream: OutputStream?
            
            Stream.getStreamsToHost(
                withName: config.imapHost,
                port: config.imapPort,
                inputStream: &inputStream,
                outputStream: &outputStream
            )
            
            guard let input = inputStream, let output = outputStream else {
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            // Enable SSL
            input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            
            input.open()
            output.open()
            
            defer {
                input.close()
                output.close()
            }
            
            do {
                // Read greeting
                _ = try readResponse(from: input)
                
                // Login
                try sendCommand("A001 LOGIN \"\(config.username)\" \"\(config.password)\"", to: output)
                let loginResponse = try readResponse(from: input)
                guard loginResponse.contains("OK") else {
                    continuation.resume(throwing: EmailError.authenticationFailed)
                    return
                }
                
                // Select INBOX
                try sendCommand("A002 SELECT INBOX", to: output)
                _ = try readResponse(from: input)
                
                // Fetch full email content by UIDs (NO truncation - fetch entire body)
                let uidSet = uids.joined(separator: ",")
                try sendCommand("A003 UID FETCH \(uidSet) (UID ENVELOPE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID IN-REPLY-TO REFERENCES)] BODY.PEEK[TEXT] BODYSTRUCTURE)", to: output)
                let fetchResponse = try readResponseLarge(from: input, timeout: 60)
                
                // Parse emails with full body
                let emails = parseIMAPFetchResponseByUID(fetchResponse)
                
                // Logout
                try sendCommand("A999 LOGOUT", to: output)
                _ = try? readResponse(from: input)
                
                continuation.resume(returning: emails)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Parse IMAP FETCH response for UID-based fetches (full body, not truncated)
    private func parseIMAPFetchResponseByUID(_ response: String) -> [EmailMessage] {
        var emails: [EmailMessage] = []
        
        // Split by FETCH boundaries
        let lines = response.components(separatedBy: "\r\n")
        var currentBlock = ""
        var inBlock = false
        
        for line in lines {
            if line.contains("FETCH") && line.hasPrefix("*") {
                // Start of new email block
                if inBlock && !currentBlock.isEmpty {
                    if let email = parseFullEmailBlock(currentBlock) {
                        emails.append(email)
                    }
                }
                currentBlock = line + "\r\n"
                inBlock = true
            } else if inBlock {
                currentBlock += line + "\r\n"
            }
        }
        
        // Parse the last block
        if inBlock && !currentBlock.isEmpty {
            if let email = parseFullEmailBlock(currentBlock) {
                emails.append(email)
            }
        }
        
        return emails
    }
    
    /// Parse a single email block from IMAP response (full body version)
    private func parseFullEmailBlock(_ block: String) -> EmailMessage? {
        // Extract UID
        var uid = ""
        if let uidMatch = block.range(of: "UID\\s+(\\d+)", options: .regularExpression) {
            let uidStr = String(block[uidMatch])
            if let numMatch = uidStr.range(of: "\\d+", options: .regularExpression) {
                uid = String(uidStr[numMatch])
            }
        }
        
        guard !uid.isEmpty else { return nil }
        
        // Extract envelope: ENVELOPE (...)
        var from = ""
        var subject = ""
        var date = ""
        
        if let envStart = block.range(of: "ENVELOPE (", options: .caseInsensitive) {
            let afterEnvelope = String(block[envStart.upperBound...])
            
            // Parse the envelope structure (simplified)
            let components = parseEnvelopeComponents(afterEnvelope)
            date = components.date
            subject = components.subject
            from = components.from
        }
        
        // Extract Message-ID header
        var messageId = ""
        var inReplyTo: String? = nil
        var references: String? = nil
        
        if let headerStart = block.range(of: "BODY[HEADER.FIELDS", options: .caseInsensitive) {
            let afterHeader = String(block[headerStart.upperBound...])
            
            // Find the header content between { and the next BODY or BODYSTRUCTURE
            if let braceStart = afterHeader.range(of: "{") {
                let afterBrace = String(afterHeader[braceStart.upperBound...])
                
                // Find where headers end
                var headerContent = ""
                var depth = 0
                var foundEnd = false
                for char in afterBrace {
                    if char == "\r" || char == "\n" {
                        if foundEnd { continue }
                    }
                    // Look for next BODY or end pattern
                    if headerContent.hasSuffix("BODY") || headerContent.hasSuffix("BODYSTRUCTURE") {
                        headerContent = String(headerContent.dropLast(headerContent.hasSuffix("BODYSTRUCTURE") ? 13 : 4))
                        break
                    }
                    headerContent.append(char)
                    if headerContent.count > 5000 { break } // Safety limit
                }
                
                // Extract Message-ID
                if let msgIdMatch = headerContent.range(of: "Message-ID:\\s*([^\\r\\n]+)", options: [.regularExpression, .caseInsensitive]) {
                    messageId = String(headerContent[msgIdMatch])
                        .replacingOccurrences(of: "Message-ID:", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces)
                }
                
                // Extract In-Reply-To
                if let replyMatch = headerContent.range(of: "In-Reply-To:\\s*([^\\r\\n]+)", options: [.regularExpression, .caseInsensitive]) {
                    inReplyTo = String(headerContent[replyMatch])
                        .replacingOccurrences(of: "In-Reply-To:", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces)
                }
                
                // Extract References
                if let refMatch = headerContent.range(of: "References:\\s*([^\\r\\n]+)", options: [.regularExpression, .caseInsensitive]) {
                    references = String(headerContent[refMatch])
                        .replacingOccurrences(of: "References:", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        // Extract FULL body text (no truncation)
        var bodyPreview = ""
        // Look for BODY[TEXT] without size limitation
        if let bodyStart = block.range(of: "BODY[TEXT]", options: .caseInsensitive) {
            let afterBody = String(block[bodyStart.upperBound...])
            
            // Find size in braces: {SIZE}
            if let braceStart = afterBody.range(of: "{"),
               let braceEnd = afterBody.range(of: "}") {
                let sizeStr = String(afterBody[braceStart.upperBound..<braceEnd.lowerBound])
                if let _ = Int(sizeStr) {
                    // Content starts after }\r\n
                    let afterBrace = String(afterBody[braceEnd.upperBound...])
                    let cleanedBody = afterBrace
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                    
                    // Find where the body ends (before BODYSTRUCTURE or closing paren)
                    var body = ""
                    for line in cleanedBody.components(separatedBy: "\r\n") {
                        if line.contains("BODYSTRUCTURE") || line.hasPrefix("A0") {
                            break
                        }
                        body += line + "\n"
                    }
                    
                    bodyPreview = body.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        
        // Parse attachments from BODYSTRUCTURE
        let attachments = parseBodystructureForAttachments(block)
        
        return EmailMessage(
            id: uid,
            messageId: messageId,
            inReplyTo: inReplyTo,
            references: references,
            from: from,
            subject: subject,
            date: date,
            bodyPreview: bodyPreview,
            attachments: attachments
        )
    }
    
    /// Parse envelope date, subject, from from the envelope string
    private func parseEnvelopeComponents(_ envelope: String) -> (date: String, subject: String, from: String) {
        // Envelope format: "date" "subject" ((from)) ((sender)) ((reply-to)) ((to)) ((cc)) ((bcc)) "in-reply-to" "message-id"
        var components: [String] = []
        var current = ""
        var inQuotes = false
        var parenDepth = 0
        
        for char in envelope {
            if char == "\"" && parenDepth == 0 {
                inQuotes.toggle()
                if !inQuotes {
                    components.append(current)
                    current = ""
                }
            } else if char == "(" && !inQuotes {
                parenDepth += 1
                current.append(char)
            } else if char == ")" && !inQuotes {
                parenDepth -= 1
                current.append(char)
                if parenDepth == 0 {
                    components.append(current)
                    current = ""
                }
            } else if inQuotes || parenDepth > 0 {
                current.append(char)
            }
            
            // Stop after we have enough components
            if components.count >= 4 { break }
        }
        
        let date = components.count > 0 ? components[0] : ""
        let subject = components.count > 1 ? components[1] : ""
        
        // Parse from address from the nested structure
        var from = ""
        if components.count > 2 {
            let fromStr = components[2]
            // Extract name and email from ((name NIL user host))
            let parts = fromStr.components(separatedBy: "\"")
            if parts.count >= 2 {
                from = parts.first(where: { !$0.isEmpty && $0 != "(" && $0 != ")" }) ?? ""
            }
            // Try to get email
            if from.isEmpty {
                // Simple extraction: look for @ pattern
                if let match = fromStr.range(of: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+", options: .regularExpression) {
                    from = String(fromStr[match])
                }
            }
        }
        
        return (date, subject, from)
    }
    
    // MARK: - IMAP: Read Emails
    
    func fetchEmails(count: Int = 5) async throws -> [EmailMessage] {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        let clampedCount = min(max(count, 1), 20)
        
        return try await withCheckedThrowingContinuation { continuation in
            var inputStream: InputStream?
            var outputStream: OutputStream?
            
            Stream.getStreamsToHost(
                withName: config.imapHost,
                port: config.imapPort,
                inputStream: &inputStream,
                outputStream: &outputStream
            )
            
            guard let input = inputStream, let output = outputStream else {
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            // Enable SSL
            input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            
            input.open()
            output.open()
            
            defer {
                input.close()
                output.close()
            }
            
            do {
                // Read greeting
                _ = try readResponse(from: input)
                
                // Login
                try sendCommand("A001 LOGIN \"\(config.username)\" \"\(config.password)\"", to: output)
                let loginResponse = try readResponse(from: input)
                guard loginResponse.contains("OK") else {
                    continuation.resume(throwing: EmailError.authenticationFailed)
                    return
                }
                
                // Select INBOX
                try sendCommand("A002 SELECT INBOX", to: output)
                let selectResponse = try readResponse(from: input)
                
                // Parse message count from EXISTS response
                var totalMessages = 0
                for line in selectResponse.components(separatedBy: "\r\n") {
                    if line.contains("EXISTS") {
                        let parts = line.components(separatedBy: " ")
                        if let countStr = parts.first(where: { Int($0) != nil }), let num = Int(countStr) {
                            totalMessages = num
                        }
                    }
                }
                
                guard totalMessages > 0 else {
                    try sendCommand("A999 LOGOUT", to: output)
                    continuation.resume(returning: [])
                    return
                }
                
                // Fetch last N emails
                let startMsg = max(1, totalMessages - clampedCount + 1)
                let endMsg = totalMessages
                
                try sendCommand("A003 FETCH \(startMsg):\(endMsg) (UID ENVELOPE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID IN-REPLY-TO REFERENCES)] BODY.PEEK[TEXT]<0.500> BODYSTRUCTURE)", to: output)
                let fetchResponse = try readResponse(from: input)
                
                // Parse emails
                let emails = parseIMAPFetchResponse(fetchResponse, startMsg: startMsg, endMsg: endMsg)
                
                // Logout
                try sendCommand("A999 LOGOUT", to: output)
                _ = try? readResponse(from: input)
                
                continuation.resume(returning: emails.reversed()) // Most recent first
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // MARK: - IMAP: Download Attachment
    
    /// Download a specific attachment from an email by UID and part ID
    /// - Parameters:
    ///   - emailUid: The UID of the email (from read_emails output)
    ///   - partId: The MIME part ID (from attachment metadata)
    /// - Returns: Tuple of (data, filename, mimeType)
    func downloadAttachment(emailUid: String, partId: String) async throws -> (data: Data, filename: String, mimeType: String) {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            var inputStream: InputStream?
            var outputStream: OutputStream?
            
            Stream.getStreamsToHost(
                withName: config.imapHost,
                port: config.imapPort,
                inputStream: &inputStream,
                outputStream: &outputStream
            )
            
            guard let input = inputStream, let output = outputStream else {
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            // Enable SSL
            input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            
            input.open()
            output.open()
            
            defer {
                input.close()
                output.close()
            }
            
            do {
                // Read greeting
                _ = try readResponse(from: input)
                
                // Login
                try sendCommand("A001 LOGIN \"\(config.username)\" \"\(config.password)\"", to: output)
                let loginResponse = try readResponse(from: input)
                guard loginResponse.contains("OK") else {
                    continuation.resume(throwing: EmailError.authenticationFailed)
                    return
                }
                
                // Select INBOX
                try sendCommand("A002 SELECT INBOX", to: output)
                _ = try readResponse(from: input)
                
                // Fetch the specific MIME part by UID
                // BODY.PEEK[partId] fetches the raw content of that part
                try sendCommand("A003 UID FETCH \(emailUid) (BODY.PEEK[\(partId)] BODYSTRUCTURE)", to: output)
                let fetchResponse = try readResponseLarge(from: input, timeout: 30)
                
                // Parse attachment data from response
                let parsed = parseAttachmentResponse(fetchResponse, partId: partId)
                
                // Logout
                try sendCommand("A999 LOGOUT", to: output)
                _ = try? readResponse(from: input)
                
                guard let attachmentData = parsed.data else {
                    continuation.resume(throwing: EmailError.attachmentNotFound)
                    return
                }
                
                continuation.resume(returning: (
                    data: attachmentData,
                    filename: parsed.filename ?? "attachment",
                    mimeType: parsed.mimeType ?? "application/octet-stream"
                ))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Download ALL attachments from an email in a single IMAP session (much faster than downloading individually)
    func downloadAllAttachments(emailUid: String, partIds: [String]) async throws -> [(partId: String, data: Data, filename: String, mimeType: String)] {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        guard !partIds.isEmpty else {
            return []
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            var inputStream: InputStream?
            var outputStream: OutputStream?
            
            Stream.getStreamsToHost(
                withName: config.imapHost,
                port: config.imapPort,
                inputStream: &inputStream,
                outputStream: &outputStream
            )
            
            guard let input = inputStream, let output = outputStream else {
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            // Enable SSL
            input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            
            input.open()
            output.open()
            
            defer {
                input.close()
                output.close()
            }
            
            do {
                // Read greeting
                _ = try readResponse(from: input)
                
                // Login
                try sendCommand("A001 LOGIN \"\(config.username)\" \"\(config.password)\"", to: output)
                let loginResponse = try readResponse(from: input)
                guard loginResponse.contains("OK") else {
                    continuation.resume(throwing: EmailError.authenticationFailed)
                    return
                }
                
                // Select INBOX
                try sendCommand("A002 SELECT INBOX", to: output)
                _ = try readResponse(from: input)
                
                var results: [(partId: String, data: Data, filename: String, mimeType: String)] = []
                
                // Fetch each attachment in sequence but ON THE SAME CONNECTION
                // This avoids connection overhead while still being reliable
                for (index, partId) in partIds.enumerated() {
                    let tag = String(format: "A%03d", index + 3)
                    try sendCommand("\(tag) UID FETCH \(emailUid) (BODY.PEEK[\(partId)] BODYSTRUCTURE)", to: output)
                    let fetchResponse = try readResponseLarge(from: input, timeout: 60, expectedTag: tag)
                    
                    let parsed = parseAttachmentResponse(fetchResponse, partId: partId)
                    
                    if let attachmentData = parsed.data {
                        results.append((
                            partId: partId,
                            data: attachmentData,
                            filename: parsed.filename ?? "attachment",
                            mimeType: parsed.mimeType ?? "application/octet-stream"
                        ))
                    }
                }
                
                // Logout
                try sendCommand("A999 LOGOUT", to: output)
                _ = try? readResponse(from: input)
                
                continuation.resume(returning: results)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Read a potentially large response (for attachments)
    private func readResponseLarge(from stream: InputStream, timeout: TimeInterval = 30, expectedTag: String? = nil) throws -> String {
        var response = ""
        let bufferSize = 16384  // Larger buffer for attachments
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let startTime = Date()
        
        // Use expected tag if provided, otherwise default to "A0" prefix
        let tagPrefix = expectedTag ?? "A0"
        
        while Date().timeIntervalSince(startTime) < timeout {
            if stream.hasBytesAvailable {
                let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                if bytesRead > 0 {
                    response += String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                    
                    // Check if we have a complete response
                    if response.contains("\r\n") {
                        let lines = response.components(separatedBy: "\r\n")
                        if let lastNonEmpty = lines.filter({ !$0.isEmpty }).last {
                            // IMAP tagged responses end with tag + status
                            if lastNonEmpty.hasPrefix(tagPrefix) && (lastNonEmpty.contains("OK") || lastNonEmpty.contains("NO") || lastNonEmpty.contains("BAD")) {
                                break
                            }
                        }
                    }
                } else if bytesRead < 0 {
                    throw EmailError.readFailed
                }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        
        if response.isEmpty {
            throw EmailError.timeout
        }
        
        return response
    }
    
    /// Parse attachment data from IMAP FETCH response
    private func parseAttachmentResponse(_ response: String, partId: String) -> (data: Data?, filename: String?, mimeType: String?) {
        var data: Data? = nil
        var filename: String? = nil
        var mimeType: String? = nil
        
        // Find the BODY[partId] section with size in braces
        let bodyPattern = "BODY\\[\(partId)\\]\\s*\\{(\\d+)\\}"
        if let bodyRegex = try? NSRegularExpression(pattern: bodyPattern, options: .caseInsensitive) {
            let nsResponse = response as NSString
            if let match = bodyRegex.firstMatch(in: response, range: NSRange(location: 0, length: nsResponse.length)),
               match.numberOfRanges >= 2 {
                let sizeRange = match.range(at: 1)
                let sizeStr = nsResponse.substring(with: sizeRange)
                let size = Int(sizeStr) ?? 0
                
                // Data starts after the closing brace and newline
                let dataStart = match.range.upperBound + 2  // Skip }\r\n
                if dataStart + size <= nsResponse.length {
                    let rawData = nsResponse.substring(with: NSRange(location: dataStart, length: size))
                    
                    // Decode from base64 (most attachments are base64 encoded)
                    if let decoded = Data(base64Encoded: rawData.replacingOccurrences(of: "\r\n", with: "")) {
                        data = decoded
                    } else {
                        // If not base64, use raw data
                        data = rawData.data(using: .utf8)
                    }
                }
            }
        }
        
        // Parse BODYSTRUCTURE for filename
        if let bsStart = response.range(of: "BODYSTRUCTURE", options: .caseInsensitive) {
            let afterBS = String(response[bsStart.upperBound...])
            
            // Look for filename
            let filenamePattern = "(?:\"NAME\"|\"FILENAME\")\\s+\"([^\"]+)\""
            if let fnRegex = try? NSRegularExpression(pattern: filenamePattern, options: .caseInsensitive) {
                let nsStr = afterBS as NSString
                if let match = fnRegex.firstMatch(in: afterBS, range: NSRange(location: 0, length: nsStr.length)),
                   match.numberOfRanges >= 2 {
                    filename = nsStr.substring(with: match.range(at: 1))
                }
            }
        }
        
        // Determine MIME type from filename extension (most reliable) or magic bytes
        if let filename = filename {
            let ext = (filename as NSString).pathExtension.lowercased()
            switch ext {
            case "jpg", "jpeg":
                mimeType = "image/jpeg"
            case "png":
                mimeType = "image/png"
            case "gif":
                mimeType = "image/gif"
            case "webp":
                mimeType = "image/webp"
            case "heic", "heif":
                mimeType = "image/heic"
            case "pdf":
                mimeType = "application/pdf"
            case "doc":
                mimeType = "application/msword"
            case "docx":
                mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            case "xls":
                mimeType = "application/vnd.ms-excel"
            case "xlsx":
                mimeType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            case "txt":
                mimeType = "text/plain"
            case "html", "htm":
                mimeType = "text/html"
            case "csv":
                mimeType = "text/csv"
            case "zip":
                mimeType = "application/zip"
            case "mp3":
                mimeType = "audio/mpeg"
            case "mp4":
                mimeType = "video/mp4"
            case "mov":
                mimeType = "video/quicktime"
            default:
                // Fall back to magic byte detection
                mimeType = detectMimeTypeFromData(data)
            }
        } else {
            // No filename - try magic bytes
            mimeType = detectMimeTypeFromData(data)
        }
        
        return (data, filename, mimeType)
    }
    
    /// Detect MIME type from file magic bytes
    private func detectMimeTypeFromData(_ data: Data?) -> String? {
        guard let data = data, data.count >= 4 else { return nil }
        
        let bytes = [UInt8](data.prefix(12))
        
        // Check JPEG: FF D8 FF
        if bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "image/jpeg"
        }
        
        // Check PNG: 89 50 4E 47
        if bytes.count >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "image/png"
        }
        
        // Check GIF: 47 49 46 38
        if bytes.count >= 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 {
            return "image/gif"
        }
        
        // Check PDF: 25 50 44 46 (%PDF)
        if bytes.count >= 4 && bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46 {
            return "application/pdf"
        }
        
        // Check WebP: RIFF....WEBP
        if bytes.count >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
           bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return "image/webp"
        }
        
        // Check ZIP/DOCX/XLSX: 50 4B 03 04
        if bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04 {
            return "application/zip"
        }
        
        return nil
    }
    
    // MARK: - Folder Name Mapping
    
    /// Maps user-friendly folder names to IMAP folder names
    /// Handles Gmail's special folder naming conventions
    private func mapFolderName(_ folder: String?) -> String {
        guard let folder = folder?.lowercased().trimmingCharacters(in: .whitespaces), !folder.isEmpty else {
            return "INBOX"
        }
        
        switch folder {
        case "inbox":
            return "INBOX"
        case "sent", "sent mail", "sent items":
            // Gmail uses "[Gmail]/Sent Mail", others may use "Sent" or "Sent Items"
            // Try Gmail format first, IMAP will fail if not supported
            if let config = config, config.imapHost.contains("gmail") {
                return "[Gmail]/Sent Mail"
            }
            return "Sent"
        case "drafts", "draft":
            if let config = config, config.imapHost.contains("gmail") {
                return "[Gmail]/Drafts"
            }
            return "Drafts"
        case "trash", "deleted", "deleted items":
            if let config = config, config.imapHost.contains("gmail") {
                return "[Gmail]/Trash"
            }
            return "Trash"
        case "spam", "junk":
            if let config = config, config.imapHost.contains("gmail") {
                return "[Gmail]/Spam"
            }
            return "Junk"
        case "all", "all mail":
            if let config = config, config.imapHost.contains("gmail") {
                return "[Gmail]/All Mail"
            }
            return "INBOX"  // Fallback for non-Gmail
        default:
            // Allow direct folder name for custom folders
            return folder
        }
    }
    
    // MARK: - IMAP: Search Emails
    
    /// Search emails using IMAP SEARCH criteria
    /// - Parameters:
    ///   - query: Optional text to search in subject and body
    ///   - from: Optional sender filter
    ///   - since: Optional date filter (emails on or after this date)
    ///   - before: Optional date filter (emails before this date)
    ///   - folder: Optional folder to search (inbox, sent, drafts, trash; defaults to inbox)
    ///   - limit: Maximum results (default 10, max 50)
    func searchEmails(
        query: String? = nil,
        from: String? = nil,
        since: Date? = nil,
        before: Date? = nil,
        folder: String? = nil,
        limit: Int = 10
    ) async throws -> [EmailMessage] {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        let clampedLimit = min(max(limit, 1), 50)
        
        // Map user-friendly folder names to IMAP folder names
        // Gmail uses special naming like "[Gmail]/Sent Mail"
        let imapFolder = mapFolderName(folder)
        
        return try await withCheckedThrowingContinuation { continuation in
            var inputStream: InputStream?
            var outputStream: OutputStream?
            
            Stream.getStreamsToHost(
                withName: config.imapHost,
                port: config.imapPort,
                inputStream: &inputStream,
                outputStream: &outputStream
            )
            
            guard let input = inputStream, let output = outputStream else {
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            // Enable SSL
            input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            
            input.open()
            output.open()
            
            defer {
                input.close()
                output.close()
            }
            
            do {
                // Read greeting
                _ = try readResponse(from: input)
                
                // Login
                try sendCommand("A001 LOGIN \"\(config.username)\" \"\(config.password)\"", to: output)
                let loginResponse = try readResponse(from: input)
                guard loginResponse.contains("OK") else {
                    continuation.resume(throwing: EmailError.authenticationFailed)
                    return
                }
                
                // Select the target folder
                try sendCommand("A002 SELECT \"\(imapFolder)\"", to: output)
                let selectResponse = try readResponse(from: input)
                
                // Build IMAP SEARCH command
                var searchCriteria: [String] = []
                
                // Add text search (subject OR body)
                if let query = query, !query.isEmpty {
                    // IMAP OR syntax: OR SUBJECT "x" BODY "x"
                    let escapedQuery = query.replacingOccurrences(of: "\"", with: "\\\"")
                    searchCriteria.append("OR SUBJECT \"\(escapedQuery)\" BODY \"\(escapedQuery)\"")
                }
                
                // Add sender filter
                if let from = from, !from.isEmpty {
                    let escapedFrom = from.replacingOccurrences(of: "\"", with: "\\\"")
                    searchCriteria.append("FROM \"\(escapedFrom)\"")
                }
                
                // Add date filters (IMAP date format: DD-Mon-YYYY)
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "dd-MMM-yyyy"
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                
                if let since = since {
                    searchCriteria.append("SINCE \(dateFormatter.string(from: since))")
                }
                
                if let before = before {
                    searchCriteria.append("BEFORE \(dateFormatter.string(from: before))")
                }
                
                // If no criteria, search ALL (but we'll limit results)
                let searchQuery = searchCriteria.isEmpty ? "ALL" : searchCriteria.joined(separator: " ")
                
                try sendCommand("A003 SEARCH \(searchQuery)", to: output)
                let searchResponse = try readResponse(from: input)
                
                // Parse message numbers from SEARCH response (format: "* SEARCH 1 2 3 4")
                var messageNumbers: [Int] = []
                for line in searchResponse.components(separatedBy: "\r\n") {
                    if line.hasPrefix("* SEARCH") {
                        let parts = line.dropFirst("* SEARCH".count).trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                        for part in parts {
                            if let num = Int(part.trimmingCharacters(in: .whitespaces)), num > 0 {
                                messageNumbers.append(num)
                            }
                        }
                    }
                }
                
                guard !messageNumbers.isEmpty else {
                    try sendCommand("A999 LOGOUT", to: output)
                    continuation.resume(returning: [])
                    return
                }
                
                // Take the last N messages (most recent) and reverse for fetching
                let limitedNumbers = Array(messageNumbers.suffix(clampedLimit))
                
                // Fetch the matched emails
                let fetchSet = limitedNumbers.map { String($0) }.joined(separator: ",")
                try sendCommand("A004 FETCH \(fetchSet) (UID ENVELOPE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID IN-REPLY-TO REFERENCES)] BODY.PEEK[TEXT]<0.500> BODYSTRUCTURE)", to: output)
                let fetchResponse = try readResponse(from: input)
                
                // Parse emails (reuse existing parser)
                let emails = parseIMAPFetchResponse(fetchResponse, startMsg: limitedNumbers.first ?? 1, endMsg: limitedNumbers.last ?? 1)
                
                // Logout
                try sendCommand("A999 LOGOUT", to: output)
                _ = try? readResponse(from: input)
                
                continuation.resume(returning: emails.reversed()) // Most recent first
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // MARK: - IMAP: Fetch Email Thread
    
    /// Fetch all emails in a conversation thread by searching for related Message-IDs
    /// - Parameter messageId: Any Message-ID from the thread (e.g., "<abc@example.com>")
    /// - Returns: All emails in the thread, sorted chronologically (oldest first)
    func fetchEmailThread(messageId: String) async throws -> [EmailMessage] {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            var inputStream: InputStream?
            var outputStream: OutputStream?
            
            Stream.getStreamsToHost(
                withName: config.imapHost,
                port: config.imapPort,
                inputStream: &inputStream,
                outputStream: &outputStream
            )
            
            guard let input = inputStream, let output = outputStream else {
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            // Enable SSL
            input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            
            input.open()
            output.open()
            
            defer {
                input.close()
                output.close()
            }
            
            do {
                // Read greeting
                _ = try readResponse(from: input)
                
                // Login
                try sendCommand("A001 LOGIN \"\(config.username)\" \"\(config.password)\"", to: output)
                let loginResponse = try readResponse(from: input)
                guard loginResponse.contains("OK") else {
                    continuation.resume(throwing: EmailError.authenticationFailed)
                    return
                }
                
                // Select INBOX
                try sendCommand("A002 SELECT INBOX", to: output)
                _ = try readResponse(from: input)
                
                // Strategy: Search for emails where:
                // 1. The Message-ID matches (this is the starting email)
                // 2. The References header contains this Message-ID (replies to it)
                // 3. The In-Reply-To header contains this Message-ID (direct replies)
                
                // First, search for emails with this Message-ID in References or as Message-ID itself
                // IMAP SEARCH with HEADER allows searching specific headers
                let cleanMessageId = messageId.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                
                // Search: HEADER References contains messageId OR HEADER Message-ID is messageId
                // Note: We search for the messageId without angle brackets in References
                try sendCommand("A003 SEARCH OR OR HEADER Message-ID \"\(cleanMessageId)\" HEADER References \"\(cleanMessageId)\" HEADER In-Reply-To \"\(cleanMessageId)\"", to: output)
                let searchResponse = try readResponse(from: input)
                
                // Parse message numbers from SEARCH response
                var messageNumbers: [Int] = []
                for line in searchResponse.components(separatedBy: "\r\n") {
                    if line.hasPrefix("* SEARCH") {
                        let parts = line.dropFirst("* SEARCH".count).trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                        for part in parts {
                            if let num = Int(part.trimmingCharacters(in: .whitespaces)), num > 0 {
                                messageNumbers.append(num)
                            }
                        }
                    }
                }
                
                // If no results from first search, try exact Message-ID match
                if messageNumbers.isEmpty {
                    try sendCommand("A004 SEARCH HEADER Message-ID \"<\(cleanMessageId)>\"", to: output)
                    let retryResponse = try readResponse(from: input)
                    
                    for line in retryResponse.components(separatedBy: "\r\n") {
                        if line.hasPrefix("* SEARCH") {
                            let parts = line.dropFirst("* SEARCH".count).trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                            for part in parts {
                                if let num = Int(part.trimmingCharacters(in: .whitespaces)), num > 0 {
                                    messageNumbers.append(num)
                                }
                            }
                        }
                    }
                }
                
                // If still no results, return empty
                if messageNumbers.isEmpty {
                    try sendCommand("A999 LOGOUT", to: output)
                    continuation.resume(returning: [])
                    return
                }
                
                // Sort and limit (max 50 thread emails)
                let sortedNumbers = messageNumbers.sorted()
                let limitedNumbers = Array(sortedNumbers.suffix(50))
                
                // Fetch the thread emails
                let fetchSet = limitedNumbers.map { String($0) }.joined(separator: ",")
                try sendCommand("A005 FETCH \(fetchSet) (UID ENVELOPE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID IN-REPLY-TO REFERENCES)] BODY.PEEK[TEXT]<0.500> BODYSTRUCTURE)", to: output)
                let fetchResponse = try readResponse(from: input)
                
                // Parse emails
                let emails = parseIMAPFetchResponse(fetchResponse, startMsg: limitedNumbers.first ?? 1, endMsg: limitedNumbers.last ?? 1)
                
                // Logout
                try sendCommand("A999 LOGOUT", to: output)
                _ = try? readResponse(from: input)
                
                // Return sorted chronologically (oldest first for thread reading)
                continuation.resume(returning: emails)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // MARK: - SMTP: Send Email (using Network.framework for reliable TLS)
    
    func sendEmail(
        to recipient: String,
        subject: String,
        body: String,
        cc: [String] = [],
        bcc: [String] = []
    ) async throws -> Bool {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            // Create TLS parameters for implicit SSL (port 465)
            let tlsOptions = NWProtocolTLS.Options()
            let tcpOptions = NWProtocolTCP.Options()
            let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
            
            let host = NWEndpoint.Host(config.smtpHost)
            guard let port = NWEndpoint.Port(rawValue: UInt16(config.smtpPort)) else {
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            let connection = NWConnection(host: host, port: port, using: parameters)
            let queue = DispatchQueue(label: "smtp.send.queue")
            var hasResumed = false
            
            // Helper to safely resume exactly once
            func resumeOnce(with result: Result<Bool, Error>) {
                guard !hasResumed else { return }
                hasResumed = true
                connection.cancel()
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            // Timeout after 60 seconds
            queue.asyncAfter(deadline: .now() + 60) {
                resumeOnce(with: .failure(EmailError.timeout))
            }
            
            connection.stateUpdateHandler = { [config, cc, bcc] state in
                switch state {
                case .ready:
                    self.performSMTPSend(
                        connection: connection,
                        config: config,
                        recipient: recipient,
                        ccRecipients: cc,
                        bccRecipients: bcc,
                        subject: subject,
                        body: body,
                        queue: queue
                    ) { result in
                        resumeOnce(with: result)
                    }
                case .failed(_):
                    resumeOnce(with: .failure(EmailError.connectionFailed))
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
        }
    }
    
    /// Performs the SMTP send protocol conversation over an established NWConnection
    private nonisolated func performSMTPSend(
        connection: NWConnection,
        config: EmailConfig,
        recipient: String,
        ccRecipients: [String],
        bccRecipients: [String],
        subject: String,
        body: String,
        queue: DispatchQueue,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        // Read greeting
        smtpReceive(connection: connection) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let greeting):
                guard greeting.hasPrefix("220") else {
                    completion(.failure(EmailError.connectionFailed))
                    return
                }
                
                // EHLO
                self.smtpSendCommand("EHLO localhost", connection: connection) { _ in
                    self.smtpReceive(connection: connection) { _ in
                        
                        // AUTH LOGIN
                        self.smtpSendCommand("AUTH LOGIN", connection: connection) { _ in
                            self.smtpReceive(connection: connection) { _ in
                                
                                // Username (base64)
                                let usernameB64 = Data(config.username.utf8).base64EncodedString()
                                self.smtpSendCommand(usernameB64, connection: connection) { _ in
                                    self.smtpReceive(connection: connection) { _ in
                                        
                                        // Password (base64)
                                        let passwordB64 = Data(config.password.utf8).base64EncodedString()
                                        self.smtpSendCommand(passwordB64, connection: connection) { _ in
                                            self.smtpReceive(connection: connection) { result in
                                                switch result {
                                                case .failure(let error):
                                                    completion(.failure(error))
                                                case .success(let authResponse):
                                                    guard authResponse.hasPrefix("235") else {
                                                        completion(.failure(EmailError.authenticationFailed))
                                                        return
                                                    }
                                                    
                                                    // MAIL FROM
                                                    self.smtpSendCommand("MAIL FROM:<\(config.username)>", connection: connection) { _ in
                                                        self.smtpReceive(connection: connection) { _ in
                                                            let recipientGroups = self.buildRecipientGroups(
                                                                to: recipient,
                                                                cc: ccRecipients,
                                                                bcc: bccRecipients
                                                            )
                                                            self.smtpSendRecipients(recipientGroups.all, connection: connection) { rcptResult in
                                                                switch rcptResult {
                                                                case .failure(let error):
                                                                    completion(.failure(error))
                                                                case .success:
                                                                    // DATA
                                                                    self.smtpSendCommand("DATA", connection: connection) { _ in
                                                                        self.smtpReceive(connection: connection) { _ in
                                                                            
                                                                            // Email content - note: body must end with \r\n.\r\n
                                                                            let dateFormatter = DateFormatter()
                                                                            dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
                                                                            let dateString = dateFormatter.string(from: Date())
                                                                            
                                                                            // Build email with proper CRLF line endings and terminating dot
                                                                            var emailLines = [
                                                                                "From: \(config.displayName) <\(config.username)>",
                                                                                "To: \(recipientGroups.to)",
                                                                                "Subject: \(subject)",
                                                                                "Date: \(dateString)",
                                                                                "MIME-Version: 1.0",
                                                                                "Content-Type: text/plain; charset=UTF-8"
                                                                            ]
                                                                            if !recipientGroups.cc.isEmpty {
                                                                                emailLines.append("Cc: \(recipientGroups.cc.joined(separator: ", "))")
                                                                            }
                                                                            emailLines.append(contentsOf: [
                                                                                "",
                                                                                body,
                                                                                "."
                                                                            ])
                                                                            let emailContent = emailLines.joined(separator: "\r\n")
                                                                            
                                                                            self.smtpSendCommand(emailContent, connection: connection) { _ in
                                                                                self.smtpReceive(connection: connection) { result in
                                                                                    switch result {
                                                                                    case .failure(let error):
                                                                                        completion(.failure(error))
                                                                                    case .success(let dataResponse):
                                                                                        guard dataResponse.hasPrefix("250") else {
                                                                                            completion(.failure(EmailError.sendFailed))
                                                                                            return
                                                                                        }
                                                                                        
                                                                                        // QUIT
                                                                                        self.smtpSendCommand("QUIT", connection: connection) { _ in
                                                                                            completion(.success(true))
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private nonisolated func buildRecipientGroups(
        to recipient: String,
        cc: [String],
        bcc: [String]
    ) -> (to: String, cc: [String], bcc: [String], all: [String]) {
        let primary = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = [primary.lowercased()]
        var uniqueCC: [String] = []
        var uniqueBCC: [String] = []
        
        for ccRecipient in cc {
            let trimmed = ccRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            uniqueCC.append(trimmed)
        }
        
        for bccRecipient in bcc {
            let trimmed = bccRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            uniqueBCC.append(trimmed)
        }
        
        return (primary, uniqueCC, uniqueBCC, [primary] + uniqueCC + uniqueBCC)
    }
    
    private nonisolated func smtpSendRecipients(
        _ recipients: [String],
        connection: NWConnection,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !recipients.isEmpty else {
            completion(.failure(EmailError.sendFailed))
            return
        }
        
        func sendRecipient(at index: Int) {
            guard index < recipients.count else {
                completion(.success(()))
                return
            }
            
            let recipient = recipients[index]
            self.smtpSendCommand("RCPT TO:<\(recipient)>", connection: connection) { sendResult in
                switch sendResult {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    self.smtpReceive(connection: connection) { receiveResult in
                        switch receiveResult {
                        case .failure(let error):
                            completion(.failure(error))
                        case .success:
                            sendRecipient(at: index + 1)
                        }
                    }
                }
            }
        }
        
        sendRecipient(at: 0)
    }
    
    /// Send an SMTP command over NWConnection
    private nonisolated func smtpSendCommand(_ command: String, connection: NWConnection, completion: @escaping (Result<Void, Error>) -> Void) {
        let data = (command + "\r\n").data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[EmailService] Send error: \(error.localizedDescription)")
                completion(.failure(EmailError.writeFailed))
            } else {
                completion(.success(()))
            }
        })
    }
    
    /// Receive an SMTP response from NWConnection
    private nonisolated func smtpReceive(connection: NWConnection, completion: @escaping (Result<String, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
            if let error = error {
                print("[EmailService] Receive error: \(error.localizedDescription)")
                completion(.failure(EmailError.readFailed))
                return
            }
            guard let data = data, let response = String(data: data, encoding: .utf8) else {
                completion(.failure(EmailError.readFailed))
                return
            }
            completion(.success(response))
        }
    }
    
    // MARK: - Test Connection
    
    func testIMAPConnection() async throws -> Bool {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            var inputStream: InputStream?
            var outputStream: OutputStream?
            
            Stream.getStreamsToHost(
                withName: config.imapHost,
                port: config.imapPort,
                inputStream: &inputStream,
                outputStream: &outputStream
            )
            
            guard let input = inputStream, let output = outputStream else {
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            
            input.open()
            output.open()
            
            defer {
                input.close()
                output.close()
            }
            
            do {
                _ = try readResponse(from: input)
                
                try sendCommand("A001 LOGIN \"\(config.username)\" \"\(config.password)\"", to: output)
                let loginResponse = try readResponse(from: input)
                
                guard loginResponse.contains("OK") else {
                    continuation.resume(throwing: EmailError.authenticationFailed)
                    return
                }
                
                try sendCommand("A002 LOGOUT", to: output)
                _ = try? readResponse(from: input)
                
                continuation.resume(returning: true)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    func testSMTPConnection() async throws -> Bool {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        print("[EmailService] testSMTPConnection: Starting via \(config.smtpHost):\(config.smtpPort)")
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            // Create TLS parameters for implicit SSL (port 465)
            let tlsOptions = NWProtocolTLS.Options()
            let tcpOptions = NWProtocolTCP.Options()
            let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
            
            let host = NWEndpoint.Host(config.smtpHost)
            guard let port = NWEndpoint.Port(rawValue: UInt16(config.smtpPort)) else {
                print("[EmailService] testSMTPConnection: Invalid port")
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            let connection = NWConnection(host: host, port: port, using: parameters)
            let queue = DispatchQueue(label: "smtp.test.queue")
            var hasResumed = false
            
            func resumeOnce(with result: Result<Bool, Error>) {
                guard !hasResumed else { return }
                hasResumed = true
                connection.cancel()
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            // Timeout after 20 seconds
            queue.asyncAfter(deadline: .now() + 20) {
                resumeOnce(with: .failure(EmailError.timeout))
            }
            
            connection.stateUpdateHandler = { [config] state in
                switch state {
                case .ready:
                    print("[EmailService] testSMTPConnection: Connection ready")
                    // Read greeting
                    self.smtpReceive(connection: connection) { result in
                        switch result {
                        case .failure(let error):
                            resumeOnce(with: .failure(error))
                        case .success(let greeting):
                            guard greeting.hasPrefix("220") else {
                                resumeOnce(with: .failure(EmailError.connectionFailed))
                                return
                            }
                            print("[EmailService] testSMTPConnection: Greeting received")
                            
                            // EHLO
                            self.smtpSendCommand("EHLO localhost", connection: connection) { _ in
                                self.smtpReceive(connection: connection) { _ in
                                    
                                    // AUTH LOGIN
                                    self.smtpSendCommand("AUTH LOGIN", connection: connection) { _ in
                                        self.smtpReceive(connection: connection) { _ in
                                            
                                            // Username
                                            let usernameB64 = Data(config.username.utf8).base64EncodedString()
                                            self.smtpSendCommand(usernameB64, connection: connection) { _ in
                                                self.smtpReceive(connection: connection) { _ in
                                                    
                                                    // Password
                                                    let passwordB64 = Data(config.password.utf8).base64EncodedString()
                                                    self.smtpSendCommand(passwordB64, connection: connection) { _ in
                                                        self.smtpReceive(connection: connection) { result in
                                                            switch result {
                                                            case .failure(let error):
                                                                resumeOnce(with: .failure(error))
                                                            case .success(let authResponse):
                                                                guard authResponse.hasPrefix("235") else {
                                                                    print("[EmailService] testSMTPConnection: Auth failed")
                                                                    resumeOnce(with: .failure(EmailError.authenticationFailed))
                                                                    return
                                                                }
                                                                
                                                                // QUIT
                                                                self.smtpSendCommand("QUIT", connection: connection) { _ in
                                                                    print("[EmailService] testSMTPConnection: SUCCESS")
                                                                    resumeOnce(with: .success(true))
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                case .waiting(let error):
                    print("[EmailService] testSMTPConnection: Waiting - \(error.localizedDescription)")
                case .failed(let error):
                    print("[EmailService] testSMTPConnection: Failed - \(error.localizedDescription)")
                    resumeOnce(with: .failure(EmailError.connectionFailed))
                case .cancelled:
                    print("[EmailService] testSMTPConnection: Cancelled")
                default:
                    break
                }
            }
            
            print("[EmailService] testSMTPConnection: Starting NWConnection...")
            connection.start(queue: queue)
        }
    }
    
    // MARK: - Helpers
    
    /// Waits for both input and output streams to fully open (including SSL handshake).
    /// Foundation streams open asynchronously, so we must poll the stream status.
    private func waitForStreamsToOpen(input: InputStream, output: OutputStream, timeout: TimeInterval = 15) throws {
        let startTime = Date()
        
        // Wait for both streams to transition to .open status
        while Date().timeIntervalSince(startTime) < timeout {
            let inputStatus = input.streamStatus
            let outputStatus = output.streamStatus
            
            // Check for errors
            if inputStatus == .error {
                print("[EmailService] Input stream error: \(input.streamError?.localizedDescription ?? "unknown")")
                throw EmailError.connectionFailed
            }
            if outputStatus == .error {
                print("[EmailService] Output stream error: \(output.streamError?.localizedDescription ?? "unknown")")
                throw EmailError.connectionFailed
            }
            
            // Check if both are open
            if inputStatus == .open && outputStatus == .open {
                print("[EmailService] Streams successfully opened (SSL handshake complete)")
                return
            }
            
            // Small delay before checking again
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        // Timeout reached
        print("[EmailService] Stream open timeout. Input: \(input.streamStatus.rawValue), Output: \(output.streamStatus.rawValue)")
        throw EmailError.timeout
    }
    
    private func sendCommand(_ command: String, to stream: OutputStream) throws {
        let data = (command + "\r\n").data(using: .utf8)!
        let bytesWritten = data.withUnsafeBytes { buffer in
            stream.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }
        if bytesWritten < 0 {
            throw EmailError.writeFailed
        }
    }
    
    private func readResponse(from stream: InputStream, timeout: TimeInterval = 10) throws -> String {
        var response = ""
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            if stream.hasBytesAvailable {
                let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                if bytesRead > 0 {
                    response += String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                    
                    // Check if we have a complete response
                    if response.contains("\r\n") {
                        // For multi-line responses, wait for completion marker
                        let lines = response.components(separatedBy: "\r\n")
                        if let lastNonEmpty = lines.filter({ !$0.isEmpty }).last {
                            // IMAP tagged responses end with tag + status
                            if lastNonEmpty.hasPrefix("A0") && (lastNonEmpty.contains("OK") || lastNonEmpty.contains("NO") || lastNonEmpty.contains("BAD")) {
                                break
                            }
                            // SMTP responses - single line ending with proper code
                            if lastNonEmpty.count >= 3 {
                                let code = String(lastNonEmpty.prefix(3))
                                if Int(code) != nil && !lastNonEmpty.dropFirst(3).hasPrefix("-") {
                                    break
                                }
                            }
                        }
                    }
                } else if bytesRead < 0 {
                    throw EmailError.readFailed
                }
            } else {
                // Small delay to avoid busy waiting
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        
        if response.isEmpty {
            throw EmailError.timeout
        }
        
        return response
    }
    
    private func parseIMAPFetchResponse(_ response: String, startMsg: Int, endMsg: Int) -> [EmailMessage] {
        var emails: [EmailMessage] = []
        
        // Simple parsing - split by FETCH responses
        let lines = response.components(separatedBy: "* ")
        
        for line in lines {
            guard line.contains("FETCH") else { continue }
            
            var from = "Unknown"
            var subject = "(No Subject)"
            var date = "Unknown"
            var bodyPreview = ""
            var uid = ""
            var messageId = ""
            var inReplyTo: String? = nil
            var references: String? = nil
            var attachments: [EmailAttachment] = []
            
            // Parse UID
            if let uidRange = line.range(of: "UID (\\d+)", options: .regularExpression) {
                uid = String(line[uidRange]).replacingOccurrences(of: "UID ", with: "")
            }
            
            // Parse headers from BODY[HEADER.FIELDS (...)]
            // The response contains Message-ID, In-Reply-To, and References headers
            if let headerStart = line.range(of: "BODY[HEADER.FIELDS", options: .caseInsensitive) {
                let afterHeader = String(line[headerStart.upperBound...])
                
                // Parse Message-ID: <...>
                if let msgIdMatch = afterHeader.range(of: "Message-ID:\\s*<[^>]+>", options: [.regularExpression, .caseInsensitive]) {
                    let msgIdLine = String(afterHeader[msgIdMatch])
                    if let angleBracketStart = msgIdLine.firstIndex(of: "<"),
                       let angleBracketEnd = msgIdLine.firstIndex(of: ">") {
                        messageId = String(msgIdLine[angleBracketStart...angleBracketEnd])
                    }
                }
                
                // Parse In-Reply-To: <...>
                if let replyMatch = afterHeader.range(of: "In-Reply-To:\\s*<[^>]+>", options: [.regularExpression, .caseInsensitive]) {
                    let replyLine = String(afterHeader[replyMatch])
                    if let angleBracketStart = replyLine.firstIndex(of: "<"),
                       let angleBracketEnd = replyLine.firstIndex(of: ">") {
                        inReplyTo = String(replyLine[angleBracketStart...angleBracketEnd])
                    }
                }
                
                // Parse References: <...> <...> ... (space-separated list of message IDs)
                if let refsMatch = afterHeader.range(of: "References:\\s*(<[^>]+>\\s*)+", options: [.regularExpression, .caseInsensitive]) {
                    let refsLine = String(afterHeader[refsMatch])
                    // Extract all <...> parts
                    var refIds: [String] = []
                    var searchRange = refsLine.startIndex..<refsLine.endIndex
                    while let startIdx = refsLine.range(of: "<", range: searchRange)?.lowerBound,
                          let endIdx = refsLine.range(of: ">", range: startIdx..<refsLine.endIndex)?.upperBound {
                        refIds.append(String(refsLine[startIdx..<endIdx]))
                        searchRange = endIdx..<refsLine.endIndex
                    }
                    if !refIds.isEmpty {
                        references = refIds.joined(separator: " ")
                    }
                }
            }
            
            // Parse ENVELOPE
            if let envelopeStart = line.range(of: "ENVELOPE (") {
                let afterEnvelope = line[envelopeStart.upperBound...]
                let components = String(afterEnvelope).components(separatedBy: "\" \"")
                
                // Envelope format: (date subject from sender reply-to to cc bcc in-reply-to message-id)
                if components.count >= 2 {
                    // Date is first
                    date = components[0].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                    if date.hasPrefix("(") { date = String(date.dropFirst()) }
                    
                    // Subject is second
                    subject = components[1].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                }
                
                // Parse From (look for NIL NIL pattern or email pattern)
                if let fromMatch = String(afterEnvelope).range(of: "\\(\\(\"[^\"]*\" NIL \"[^\"]*\" \"[^\"]*\"\\)\\)", options: .regularExpression) {
                    let fromPart = String(String(afterEnvelope)[fromMatch])
                    let parts = fromPart.components(separatedBy: "\" \"")
                    if parts.count >= 4 {
                        let name = parts[0].replacingOccurrences(of: "((\"", with: "")
                        let mailbox = parts[2]
                        let host = parts[3].replacingOccurrences(of: "\"))", with: "")
                        from = name.isEmpty ? "\(mailbox)@\(host)" : "\(name) <\(mailbox)@\(host)>"
                    }
                }
            }
            
            // Parse body preview
            if let bodyStart = line.range(of: "BODY[TEXT]<0>") ?? line.range(of: "BODY[TEXT]<0.500>") {
                let afterBody = line[bodyStart.upperBound...]
                if let openBrace = afterBody.firstIndex(of: "{"),
                   let closeBrace = afterBody.firstIndex(of: "}") {
                    let afterBrace = afterBody[afterBody.index(after: closeBrace)...]
                    bodyPreview = String(afterBrace.prefix(500))
                        .replacingOccurrences(of: "\r\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            
            // Parse BODYSTRUCTURE for attachments
            attachments = parseBodystructureForAttachments(line)
            
            if uid.isEmpty {
                uid = UUID().uuidString
            }
            
            // Generate a fallback Message-ID if not found
            if messageId.isEmpty {
                messageId = "<\(uid)@unknown>"
            }
            
            emails.append(EmailMessage(
                id: uid,
                messageId: messageId,
                inReplyTo: inReplyTo,
                references: references,
                from: from,
                subject: subject,
                date: date,
                bodyPreview: String(bodyPreview.prefix(300)),
                attachments: attachments
            ))
        }
        
        return emails
    }
    
    /// Parse BODYSTRUCTURE to extract attachment metadata
    /// IMAP BODYSTRUCTURE format for multipart: (part1)(part2)... "MIXED" ...
    /// Each part: ("type" "subtype" ("param" "value") NIL NIL "encoding" size ...)
    private func parseBodystructureForAttachments(_ response: String) -> [EmailAttachment] {
        var attachments: [EmailAttachment] = []
        
        // Find BODYSTRUCTURE section
        guard let bsStart = response.range(of: "BODYSTRUCTURE (", options: .caseInsensitive) else {
            return []
        }
        
        let afterBS = response[bsStart.upperBound...]
        
        // Find matching closing paren for BODYSTRUCTURE
        var depth = 1
        var bodystructure = ""
        for char in afterBS {
            if char == "(" { depth += 1 }
            if char == ")" { depth -= 1 }
            if depth == 0 { break }
            bodystructure.append(char)
        }
        
        // Look for attachment patterns in BODYSTRUCTURE
        // Attachments typically have: "application" or "image" type with filename in disposition
        // Pattern: ("type" "subtype" ... ("ATTACHMENT" ("filename" "name.ext")) ...)
        
        // Extract all parts with filenames using regex pattern for "NAME" or "FILENAME" parameter
        let filenamePattern = "(?:\"NAME\"|\"FILENAME\")\\s+\"([^\"]+)\""
        if let filenameRegex = try? NSRegularExpression(pattern: filenamePattern, options: .caseInsensitive) {
            let nsString = bodystructure as NSString
            let matches = filenameRegex.matches(in: bodystructure, range: NSRange(location: 0, length: nsString.length))
            
            for match in matches {
                if match.numberOfRanges >= 2 {
                    let filenameRange = match.range(at: 1)
                    let filename = nsString.substring(with: filenameRange)
                    
                    // Now try to find the part info around this filename
                    // Look backwards for the type/subtype and encoding
                    let partInfo = extractPartInfo(bodystructure: bodystructure, filenameLocation: match.range.location)
                    
                    attachments.append(EmailAttachment(
                        partId: partInfo.partId,
                        filename: filename,
                        mimeType: partInfo.mimeType,
                        size: partInfo.size,
                        encoding: partInfo.encoding
                    ))
                }
            }
        }
        
        // Also check for inline images and other non-text parts without explicit filename
        // Pattern for binary parts: ("image" "jpeg" ...) or ("application" "pdf" ...)
        let partPatterns = [
            ("image", "(?:\"image\"\\s+\"([^\"]+)\")", "image"),
            ("application", "(?:\"application\"\\s+\"([^\"]+)\")", "application")
        ]
        
        for (_, pattern, typePrefix) in partPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsString = bodystructure as NSString
                let matches = regex.matches(in: bodystructure, range: NSRange(location: 0, length: nsString.length))
                
                for match in matches {
                    if match.numberOfRanges >= 2 {
                        let subtypeRange = match.range(at: 1)
                        let subtype = nsString.substring(with: subtypeRange).lowercased()
                        let mimeType = "\(typePrefix)/\(subtype)"
                        
                        // Skip if we already have this from filename extraction
                        let alreadyFound = attachments.contains { $0.mimeType == mimeType }
                        if !alreadyFound && subtype != "plain" && subtype != "html" {
                            // Extract part info for this match
                            let partInfo = extractPartInfoFromMatch(bodystructure: bodystructure, matchLocation: match.range.location)
                            
                            // Only add if it has a name or seems like an attachment
                            if partInfo.hasAttachmentIndicator {
                                attachments.append(EmailAttachment(
                                    partId: partInfo.partId,
                                    filename: partInfo.filename ?? "attachment.\(subtype)",
                                    mimeType: mimeType,
                                    size: partInfo.size,
                                    encoding: partInfo.encoding
                                ))
                            }
                        }
                    }
                }
            }
        }
        
        return attachments
    }
    
    /// Extract part information (MIME type, encoding, size) from BODYSTRUCTURE near a filename
    private func extractPartInfo(bodystructure: String, filenameLocation: Int) -> (partId: String, mimeType: String, size: Int, encoding: String) {
        // Default values
        var partId = "1"
        var mimeType = "application/octet-stream"
        var size = 0
        var encoding = "base64"
        
        // Look backwards from filename to find the opening paren and part info
        let prefix = String(bodystructure.prefix(filenameLocation))
        
        // Find the most recent type/subtype pair (e.g., "application" "pdf")
        let typePattern = "\"(\\w+)\"\\s+\"(\\w+)\""
        if let typeRegex = try? NSRegularExpression(pattern: typePattern, options: .caseInsensitive) {
            let nsPrefix = prefix as NSString
            let matches = typeRegex.matches(in: prefix, range: NSRange(location: 0, length: nsPrefix.length))
            if let lastMatch = matches.last, lastMatch.numberOfRanges >= 3 {
                let type = nsPrefix.substring(with: lastMatch.range(at: 1)).lowercased()
                let subtype = nsPrefix.substring(with: lastMatch.range(at: 2)).lowercased()
                mimeType = "\(type)/\(subtype)"
            }
        }
        
        // Look for encoding (base64, quoted-printable, etc.) - usually follows size
        let encodingPattern = "\"(BASE64|QUOTED-PRINTABLE|7BIT|8BIT)\""
        if let encRegex = try? NSRegularExpression(pattern: encodingPattern, options: .caseInsensitive) {
            let nsBS = bodystructure as NSString
            let matches = encRegex.matches(in: bodystructure, range: NSRange(location: 0, length: min(filenameLocation + 200, nsBS.length)))
            if let match = matches.last, match.numberOfRanges >= 2 {
                encoding = nsBS.substring(with: match.range(at: 1)).lowercased()
            }
        }
        
        // Look for size (numeric value after encoding)
        let sizePattern = "\\s(\\d{2,})\\s"
        if let sizeRegex = try? NSRegularExpression(pattern: sizePattern, options: []) {
            let nsBS = bodystructure as NSString
            let searchRange = NSRange(location: max(0, filenameLocation - 100), length: min(200, nsBS.length - max(0, filenameLocation - 100)))
            let matches = sizeRegex.matches(in: bodystructure, range: searchRange)
            if let match = matches.first, match.numberOfRanges >= 2 {
                let sizeStr = nsBS.substring(with: match.range(at: 1))
                size = Int(sizeStr) ?? 0
            }
        }
        
        // Calculate part ID based on position (simplified - counts opening parens)
        var depth = 0
        var partNumber = 1
        for (idx, char) in bodystructure.enumerated() {
            if idx >= filenameLocation { break }
            if char == "(" { 
                depth += 1
                if depth == 2 { partNumber += 1 }  // New sibling part
            }
            if char == ")" { depth -= 1 }
        }
        partId = "\(partNumber)"
        
        return (partId, mimeType, size, encoding)
    }
    
    /// Extract part info from a type match location
    private func extractPartInfoFromMatch(bodystructure: String, matchLocation: Int) -> (partId: String, mimeType: String, size: Int, encoding: String, filename: String?, hasAttachmentIndicator: Bool) {
        var partId = "1"
        var mimeType = "application/octet-stream"
        var size = 0
        var encoding = "base64"
        var filename: String? = nil
        var hasAttachmentIndicator = false
        
        // Check for ATTACHMENT or INLINE disposition nearby
        let searchRange = bodystructure.index(bodystructure.startIndex, offsetBy: min(matchLocation, bodystructure.count - 1))
        let searchEnd = bodystructure.index(searchRange, offsetBy: min(500, bodystructure.distance(from: searchRange, to: bodystructure.endIndex)))
        let searchSection = String(bodystructure[searchRange..<searchEnd])
        
        if searchSection.uppercased().contains("ATTACHMENT") || searchSection.uppercased().contains("INLINE") {
            hasAttachmentIndicator = true
        }
        
        // Look for filename in this section
        let filenamePattern = "(?:\"NAME\"|\"FILENAME\")\\s+\"([^\"]+)\""
        if let filenameRegex = try? NSRegularExpression(pattern: filenamePattern, options: .caseInsensitive) {
            let nsSection = searchSection as NSString
            if let match = filenameRegex.firstMatch(in: searchSection, range: NSRange(location: 0, length: nsSection.length)),
               match.numberOfRanges >= 2 {
                filename = nsSection.substring(with: match.range(at: 1))
                hasAttachmentIndicator = true
            }
        }
        
        // Extract encoding
        let encodingPattern = "\"(BASE64|QUOTED-PRINTABLE|7BIT|8BIT)\""
        if let encRegex = try? NSRegularExpression(pattern: encodingPattern, options: .caseInsensitive) {
            let nsSection = searchSection as NSString
            if let match = encRegex.firstMatch(in: searchSection, range: NSRange(location: 0, length: nsSection.length)),
               match.numberOfRanges >= 2 {
                encoding = nsSection.substring(with: match.range(at: 1)).lowercased()
            }
        }
        
        // Extract size
        let sizePattern = "\\s(\\d{3,})\\s"
        if let sizeRegex = try? NSRegularExpression(pattern: sizePattern, options: []) {
            let nsSection = searchSection as NSString
            if let match = sizeRegex.firstMatch(in: searchSection, range: NSRange(location: 0, length: nsSection.length)),
               match.numberOfRanges >= 2 {
                size = Int(nsSection.substring(with: match.range(at: 1))) ?? 0
            }
        }
        
        return (partId, mimeType, size, encoding, filename, hasAttachmentIndicator)
    }
    
    // MARK: - SMTP: Reply to Email (with threading headers)
    
    func replyToEmail(
        inReplyTo: String,
        references: String?,
        to recipient: String,
        subject: String,
        body: String
    ) async throws -> Bool {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            // Create TLS parameters for implicit SSL (port 465)
            let tlsOptions = NWProtocolTLS.Options()
            let tcpOptions = NWProtocolTCP.Options()
            let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
            
            let host = NWEndpoint.Host(config.smtpHost)
            guard let port = NWEndpoint.Port(rawValue: UInt16(config.smtpPort)) else {
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            let connection = NWConnection(host: host, port: port, using: parameters)
            let queue = DispatchQueue(label: "smtp.reply.queue")
            var hasResumed = false
            
            func resumeOnce(with result: Result<Bool, Error>) {
                guard !hasResumed else { return }
                hasResumed = true
                connection.cancel()
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            // Timeout after 60 seconds
            queue.asyncAfter(deadline: .now() + 60) {
                resumeOnce(with: .failure(EmailError.timeout))
            }
            
            connection.stateUpdateHandler = { [config] state in
                switch state {
                case .ready:
                    self.performSMTPReply(
                        connection: connection,
                        config: config,
                        inReplyTo: inReplyTo,
                        references: references,
                        recipient: recipient,
                        subject: subject,
                        body: body,
                        queue: queue
                    ) { result in
                        resumeOnce(with: result)
                    }
                case .failed(_):
                    resumeOnce(with: .failure(EmailError.connectionFailed))
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
        }
    }
    
    /// Performs the SMTP reply protocol conversation with threading headers
    private nonisolated func performSMTPReply(
        connection: NWConnection,
        config: EmailConfig,
        inReplyTo: String,
        references: String?,
        recipient: String,
        subject: String,
        body: String,
        queue: DispatchQueue,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        // Read greeting
        smtpReceive(connection: connection) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let greeting):
                guard greeting.hasPrefix("220") else {
                    completion(.failure(EmailError.connectionFailed))
                    return
                }
                
                // EHLO
                self.smtpSendCommand("EHLO localhost", connection: connection) { _ in
                    self.smtpReceive(connection: connection) { _ in
                        
                        // AUTH LOGIN
                        self.smtpSendCommand("AUTH LOGIN", connection: connection) { _ in
                            self.smtpReceive(connection: connection) { _ in
                                
                                // Username (base64)
                                let usernameB64 = Data(config.username.utf8).base64EncodedString()
                                self.smtpSendCommand(usernameB64, connection: connection) { _ in
                                    self.smtpReceive(connection: connection) { _ in
                                        
                                        // Password (base64)
                                        let passwordB64 = Data(config.password.utf8).base64EncodedString()
                                        self.smtpSendCommand(passwordB64, connection: connection) { _ in
                                            self.smtpReceive(connection: connection) { result in
                                                switch result {
                                                case .failure(let error):
                                                    completion(.failure(error))
                                                case .success(let authResponse):
                                                    guard authResponse.hasPrefix("235") else {
                                                        completion(.failure(EmailError.authenticationFailed))
                                                        return
                                                    }
                                                    
                                                    // MAIL FROM
                                                    self.smtpSendCommand("MAIL FROM:<\(config.username)>", connection: connection) { _ in
                                                        self.smtpReceive(connection: connection) { _ in
                                                            
                                                            // RCPT TO
                                                            self.smtpSendCommand("RCPT TO:<\(recipient)>", connection: connection) { _ in
                                                                self.smtpReceive(connection: connection) { _ in
                                                                    
                                                                    // DATA
                                                                    self.smtpSendCommand("DATA", connection: connection) { _ in
                                                                        self.smtpReceive(connection: connection) { _ in
                                                                            
                                                                            // Email content with threading headers
                                                                            let dateFormatter = DateFormatter()
                                                                            dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
                                                                            let dateString = dateFormatter.string(from: Date())
                                                                            
                                                                            // Build References header (original + in-reply-to)
                                                                            let refsHeader = references.map { "\($0) \(inReplyTo)" } ?? inReplyTo
                                                                            
                                                                            // Build email with CRLF line endings, threading headers, and terminating dot
                                                                            var emailLines = [
                                                                                "From: \(config.displayName) <\(config.username)>",
                                                                                "To: \(recipient)",
                                                                                "Subject: \(subject)",
                                                                                "Date: \(dateString)",
                                                                                "In-Reply-To: \(inReplyTo)",
                                                                                "References: \(refsHeader)",
                                                                                "MIME-Version: 1.0",
                                                                                "Content-Type: text/plain; charset=UTF-8",
                                                                                "",
                                                                                body,
                                                                                "."
                                                                            ]
                                                                            let emailContent = emailLines.joined(separator: "\r\n")
                                                                            
                                                                            self.smtpSendCommand(emailContent, connection: connection) { _ in
                                                                                self.smtpReceive(connection: connection) { result in
                                                                                    switch result {
                                                                                    case .failure(let error):
                                                                                        completion(.failure(error))
                                                                                    case .success(let dataResponse):
                                                                                        guard dataResponse.hasPrefix("250") else {
                                                                                            completion(.failure(EmailError.sendFailed))
                                                                                            return
                                                                                        }
                                                                                        
                                                                                        // QUIT
                                                                                        self.smtpSendCommand("QUIT", connection: connection) { _ in
                                                                                            completion(.success(true))
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - SMTP: Forward Email
    
    /// Forward an email to another recipient with formatted forwarded content
    func forwardEmail(
        to recipient: String,
        originalFrom: String,
        originalDate: String,
        originalSubject: String,
        originalBody: String,
        comment: String?
    ) async throws -> Bool {
        // Build the forward subject
        let forwardSubject = originalSubject.hasPrefix("Fwd:") ? originalSubject : "Fwd: \(originalSubject)"
        
        // Build the forward body with proper formatting
        var forwardBody = ""
        
        // Add optional comment at the top
        if let comment = comment, !comment.isEmpty {
            forwardBody += "\(comment)\n\n"
        }
        
        // Add forwarded message header
        forwardBody += "---------- Forwarded message ---------\n"
        forwardBody += "From: \(originalFrom)\n"
        forwardBody += "Date: \(originalDate)\n"
        forwardBody += "Subject: \(originalSubject)\n"
        forwardBody += "\n"
        forwardBody += originalBody
        
        // Use the existing sendEmail method
        return try await sendEmail(to: recipient, subject: forwardSubject, body: forwardBody)
    }
    
    // MARK: - SMTP: Forward Email with Attachments
    
    /// Attachment data for forwarding
    struct ForwardAttachment {
        let data: Data
        let filename: String
        let mimeType: String
    }
    
    /// Forward an email to another recipient with attachments
    func forwardEmailWithAttachments(
        to recipient: String,
        originalFrom: String,
        originalDate: String,
        originalSubject: String,
        originalBody: String,
        comment: String?,
        attachments: [ForwardAttachment]
    ) async throws -> Bool {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        // Build the forward subject
        let forwardSubject = originalSubject.hasPrefix("Fwd:") ? originalSubject : "Fwd: \(originalSubject)"
        
        // Build the forward body with proper formatting
        var forwardBody = ""
        
        // Add optional comment at the top
        if let comment = comment, !comment.isEmpty {
            forwardBody += "\(comment)\n\n"
        }
        
        // Add forwarded message header
        forwardBody += "---------- Forwarded message ---------\n"
        forwardBody += "From: \(originalFrom)\n"
        forwardBody += "Date: \(originalDate)\n"
        forwardBody += "Subject: \(originalSubject)\n"
        forwardBody += "\n"
        forwardBody += originalBody
        
        // If no attachments, use simple send
        if attachments.isEmpty {
            return try await sendEmail(to: recipient, subject: forwardSubject, body: forwardBody)
        }
        
        // Otherwise, build MIME multipart message
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let tlsOptions = NWProtocolTLS.Options()
            let tcpOptions = NWProtocolTCP.Options()
            let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
            
            let host = NWEndpoint.Host(config.smtpHost)
            guard let port = NWEndpoint.Port(rawValue: UInt16(config.smtpPort)) else {
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            let connection = NWConnection(host: host, port: port, using: parameters)
            let queue = DispatchQueue(label: "smtp.forward.attachments.queue")
            var hasResumed = false
            
            func resumeOnce(with result: Result<Bool, Error>) {
                guard !hasResumed else { return }
                hasResumed = true
                connection.cancel()
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            // Longer timeout for attachments (180 seconds for multiple attachments)
            queue.asyncAfter(deadline: .now() + 180) {
                resumeOnce(with: .failure(EmailError.timeout))
            }
            
            connection.stateUpdateHandler = { [config, forwardSubject, forwardBody, attachments] state in
                switch state {
                case .ready:
                    self.performSMTPForwardWithAttachments(
                        connection: connection,
                        config: config,
                        recipient: recipient,
                        subject: forwardSubject,
                        body: forwardBody,
                        attachments: attachments,
                        queue: queue
                    ) { result in
                        resumeOnce(with: result)
                    }
                case .failed(_):
                    resumeOnce(with: .failure(EmailError.connectionFailed))
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
        }
    }
    
    /// Performs SMTP send with multiple MIME attachments for forwarding
    private nonisolated func performSMTPForwardWithAttachments(
        connection: NWConnection,
        config: EmailConfig,
        recipient: String,
        subject: String,
        body: String,
        attachments: [ForwardAttachment],
        queue: DispatchQueue,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        // Read greeting
        smtpReceive(connection: connection) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let greeting):
                guard greeting.hasPrefix("220") else {
                    completion(.failure(EmailError.connectionFailed))
                    return
                }
                
                // EHLO
                self.smtpSendCommand("EHLO localhost", connection: connection) { _ in
                    self.smtpReceive(connection: connection) { _ in
                        
                        // AUTH LOGIN
                        self.smtpSendCommand("AUTH LOGIN", connection: connection) { _ in
                            self.smtpReceive(connection: connection) { _ in
                                
                                // Username (base64)
                                let usernameB64 = Data(config.username.utf8).base64EncodedString()
                                self.smtpSendCommand(usernameB64, connection: connection) { _ in
                                    self.smtpReceive(connection: connection) { _ in
                                        
                                        // Password (base64)
                                        let passwordB64 = Data(config.password.utf8).base64EncodedString()
                                        self.smtpSendCommand(passwordB64, connection: connection) { _ in
                                            self.smtpReceive(connection: connection) { result in
                                                switch result {
                                                case .failure(let error):
                                                    completion(.failure(error))
                                                case .success(let authResponse):
                                                    guard authResponse.hasPrefix("235") else {
                                                        completion(.failure(EmailError.authenticationFailed))
                                                        return
                                                    }
                                                    
                                                    // MAIL FROM
                                                    self.smtpSendCommand("MAIL FROM:<\(config.username)>", connection: connection) { _ in
                                                        self.smtpReceive(connection: connection) { _ in
                                                            
                                                            // RCPT TO
                                                            self.smtpSendCommand("RCPT TO:<\(recipient)>", connection: connection) { _ in
                                                                self.smtpReceive(connection: connection) { _ in
                                                                    
                                                                    // DATA
                                                                    self.smtpSendCommand("DATA", connection: connection) { _ in
                                                                        self.smtpReceive(connection: connection) { _ in
                                                                            
                                                                            // Build MIME multipart email with all attachments
                                                                            let boundary = "----=_Part_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                                                                            let dateFormatter = DateFormatter()
                                                                            dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
                                                                            let dateString = dateFormatter.string(from: Date())
                                                                            
                                                                            var emailLines = [
                                                                                "From: \(config.displayName) <\(config.username)>",
                                                                                "To: \(recipient)",
                                                                                "Subject: \(subject)",
                                                                                "Date: \(dateString)",
                                                                                "MIME-Version: 1.0",
                                                                                "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
                                                                                "",
                                                                                "--\(boundary)",
                                                                                "Content-Type: text/plain; charset=UTF-8",
                                                                                "Content-Transfer-Encoding: 7bit",
                                                                                "",
                                                                                body,
                                                                                ""
                                                                            ]
                                                                            
                                                                            // Add each attachment
                                                                            for attachment in attachments {
                                                                                let attachmentBase64 = attachment.data.base64EncodedString(options: .lineLength76Characters)
                                                                                emailLines.append("--\(boundary)")
                                                                                emailLines.append("Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"")
                                                                                emailLines.append("Content-Transfer-Encoding: base64")
                                                                                emailLines.append("Content-Disposition: attachment; filename=\"\(attachment.filename)\"")
                                                                                emailLines.append("")
                                                                                emailLines.append(attachmentBase64)
                                                                                emailLines.append("")
                                                                            }
                                                                            
                                                                            // Close boundary and end with dot
                                                                            emailLines.append("--\(boundary)--")
                                                                            emailLines.append(".")
                                                                            
                                                                            let emailContent = emailLines.joined(separator: "\r\n")
                                                                            
                                                                            self.smtpSendCommand(emailContent, connection: connection) { _ in
                                                                                self.smtpReceive(connection: connection) { result in
                                                                                    switch result {
                                                                                    case .failure(let error):
                                                                                        completion(.failure(error))
                                                                                    case .success(let dataResponse):
                                                                                        guard dataResponse.hasPrefix("250") else {
                                                                                            completion(.failure(EmailError.sendFailed))
                                                                                            return
                                                                                        }
                                                                                        
                                                                                        // QUIT
                                                                                        self.smtpSendCommand("QUIT", connection: connection) { _ in
                                                                                            completion(.success(true))
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - SMTP: Send Email with Attachments
    
    /// Send an email with one or more file attachments
    func sendEmailWithAttachments(
        to recipient: String,
        subject: String,
        body: String,
        cc: [String] = [],
        bcc: [String] = [],
        attachments: [(url: URL, name: String)]
    ) async throws -> Bool {
        guard let config = config else {
            throw EmailError.notConfigured
        }
        
        // Read all attachment data
        var attachmentDataList: [(data: Data, name: String, mimeType: String)] = []
        var totalSize: Int = 0
        
        for attachment in attachments {
            let data: Data
            do {
                data = try Data(contentsOf: attachment.url)
            } catch {
                throw EmailError.attachmentFailed
            }
            totalSize += data.count
            let mimeType = mimeTypeForExtension(attachment.url.pathExtension)
            attachmentDataList.append((data: data, name: attachment.name, mimeType: mimeType))
        }
        
        // Warn about large attachments (>15MB after base64 encoding ~= 20MB)
        let totalSizeMB = Double(totalSize) / (1024 * 1024)
        if totalSizeMB > 15 {
            print("[EmailService] Warning: Large total attachments (\(String(format: "%.1f", totalSizeMB)) MB) may fail with some email providers")
        }
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let tlsOptions = NWProtocolTLS.Options()
            let tcpOptions = NWProtocolTCP.Options()
            let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
            
            let host = NWEndpoint.Host(config.smtpHost)
            guard let port = NWEndpoint.Port(rawValue: UInt16(config.smtpPort)) else {
                continuation.resume(throwing: EmailError.connectionFailed)
                return
            }
            
            let connection = NWConnection(host: host, port: port, using: parameters)
            let queue = DispatchQueue(label: "smtp.attachment.queue")
            var hasResumed = false
            
            func resumeOnce(with result: Result<Bool, Error>) {
                guard !hasResumed else { return }
                hasResumed = true
                connection.cancel()
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            
            // Longer timeout for attachments (120 seconds + 30s per attachment)
            let timeoutSeconds = 120 + (attachments.count * 30)
            queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                resumeOnce(with: .failure(EmailError.timeout))
            }
            
            connection.stateUpdateHandler = { [config, attachmentDataList, cc, bcc] state in
                switch state {
                case .ready:
                    self.performSMTPSendWithMultipleAttachments(
                        connection: connection,
                        config: config,
                        recipient: recipient,
                        ccRecipients: cc,
                        bccRecipients: bcc,
                        subject: subject,
                        body: body,
                        attachments: attachmentDataList,
                        queue: queue
                    ) { result in
                        resumeOnce(with: result)
                    }
                case .failed(_):
                    resumeOnce(with: .failure(EmailError.connectionFailed))
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
        }
    }
    
    /// Legacy single-attachment method (calls multi-attachment version)
    func sendEmailWithAttachment(
        to recipient: String,
        subject: String,
        body: String,
        attachmentURL: URL,
        attachmentName: String? = nil,
        cc: [String] = [],
        bcc: [String] = []
    ) async throws -> Bool {
        let name = attachmentName ?? attachmentURL.lastPathComponent
        return try await sendEmailWithAttachments(
            to: recipient,
            subject: subject,
            body: body,
            cc: cc,
            bcc: bcc,
            attachments: [(url: attachmentURL, name: name)]
        )
    }
    
    /// MIME type for file extension
    private nonisolated func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
    
    /// Performs SMTP send with MIME multipart attachment
    private nonisolated func performSMTPSendWithAttachment(
        connection: NWConnection,
        config: EmailConfig,
        recipient: String,
        subject: String,
        body: String,
        attachmentData: Data,
        attachmentName: String,
        attachmentMimeType: String,
        queue: DispatchQueue,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        // Read greeting
        smtpReceive(connection: connection) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let greeting):
                guard greeting.hasPrefix("220") else {
                    completion(.failure(EmailError.connectionFailed))
                    return
                }
                
                // EHLO
                self.smtpSendCommand("EHLO localhost", connection: connection) { _ in
                    self.smtpReceive(connection: connection) { _ in
                        
                        // AUTH LOGIN
                        self.smtpSendCommand("AUTH LOGIN", connection: connection) { _ in
                            self.smtpReceive(connection: connection) { _ in
                                
                                // Username (base64)
                                let usernameB64 = Data(config.username.utf8).base64EncodedString()
                                self.smtpSendCommand(usernameB64, connection: connection) { _ in
                                    self.smtpReceive(connection: connection) { _ in
                                        
                                        // Password (base64)
                                        let passwordB64 = Data(config.password.utf8).base64EncodedString()
                                        self.smtpSendCommand(passwordB64, connection: connection) { _ in
                                            self.smtpReceive(connection: connection) { result in
                                                switch result {
                                                case .failure(let error):
                                                    completion(.failure(error))
                                                case .success(let authResponse):
                                                    guard authResponse.hasPrefix("235") else {
                                                        completion(.failure(EmailError.authenticationFailed))
                                                        return
                                                    }
                                                    
                                                    // MAIL FROM
                                                    self.smtpSendCommand("MAIL FROM:<\(config.username)>", connection: connection) { _ in
                                                        self.smtpReceive(connection: connection) { _ in
                                                            
                                                            // RCPT TO
                                                            self.smtpSendCommand("RCPT TO:<\(recipient)>", connection: connection) { _ in
                                                                self.smtpReceive(connection: connection) { _ in
                                                                    
                                                                    // DATA
                                                                    self.smtpSendCommand("DATA", connection: connection) { _ in
                                                                        self.smtpReceive(connection: connection) { _ in
                                                                            
                                                                            // Build MIME multipart email
                                                                            let boundary = "----=_Part_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                                                                            let dateFormatter = DateFormatter()
                                                                            dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
                                                                            let dateString = dateFormatter.string(from: Date())
                                                                            
                                                                            // Base64 encode attachment
                                                                            let attachmentBase64 = attachmentData.base64EncodedString(options: .lineLength76Characters)
                                                                            
                                                                            let emailLines = [
                                                                                "From: \(config.displayName) <\(config.username)>",
                                                                                "To: \(recipient)",
                                                                                "Subject: \(subject)",
                                                                                "Date: \(dateString)",
                                                                                "MIME-Version: 1.0",
                                                                                "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
                                                                                "",
                                                                                "--\(boundary)",
                                                                                "Content-Type: text/plain; charset=UTF-8",
                                                                                "Content-Transfer-Encoding: 7bit",
                                                                                "",
                                                                                body,
                                                                                "",
                                                                                "--\(boundary)",
                                                                                "Content-Type: \(attachmentMimeType); name=\"\(attachmentName)\"",
                                                                                "Content-Transfer-Encoding: base64",
                                                                                "Content-Disposition: attachment; filename=\"\(attachmentName)\"",
                                                                                "",
                                                                                attachmentBase64,
                                                                                "",
                                                                                "--\(boundary)--",
                                                                                "."
                                                                            ]
                                                                            let emailContent = emailLines.joined(separator: "\r\n")
                                                                            
                                                                            self.smtpSendCommand(emailContent, connection: connection) { _ in
                                                                                self.smtpReceive(connection: connection) { result in
                                                                                    switch result {
                                                                                    case .failure(let error):
                                                                                        completion(.failure(error))
                                                                                    case .success(let dataResponse):
                                                                                        guard dataResponse.hasPrefix("250") else {
                                                                                            completion(.failure(EmailError.sendFailed))
                                                                                            return
                                                                                        }
                                                                                        
                                                                                        // QUIT
                                                                                        self.smtpSendCommand("QUIT", connection: connection) { _ in
                                                                                            completion(.success(true))
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    /// Performs SMTP send with MIME multipart for MULTIPLE attachments
    private nonisolated func performSMTPSendWithMultipleAttachments(
        connection: NWConnection,
        config: EmailConfig,
        recipient: String,
        ccRecipients: [String],
        bccRecipients: [String],
        subject: String,
        body: String,
        attachments: [(data: Data, name: String, mimeType: String)],
        queue: DispatchQueue,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        // Read greeting
        smtpReceive(connection: connection) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let greeting):
                guard greeting.hasPrefix("220") else {
                    completion(.failure(EmailError.connectionFailed))
                    return
                }
                
                // EHLO
                self.smtpSendCommand("EHLO localhost", connection: connection) { _ in
                    self.smtpReceive(connection: connection) { _ in
                        
                        // AUTH LOGIN
                        self.smtpSendCommand("AUTH LOGIN", connection: connection) { _ in
                            self.smtpReceive(connection: connection) { _ in
                                
                                // Username (base64)
                                let usernameB64 = Data(config.username.utf8).base64EncodedString()
                                self.smtpSendCommand(usernameB64, connection: connection) { _ in
                                    self.smtpReceive(connection: connection) { _ in
                                        
                                        // Password (base64)
                                        let passwordB64 = Data(config.password.utf8).base64EncodedString()
                                        self.smtpSendCommand(passwordB64, connection: connection) { _ in
                                            self.smtpReceive(connection: connection) { result in
                                                switch result {
                                                case .failure(let error):
                                                    completion(.failure(error))
                                                case .success(let authResponse):
                                                    guard authResponse.hasPrefix("235") else {
                                                        completion(.failure(EmailError.authenticationFailed))
                                                        return
                                                    }
                                                    
                                                    // MAIL FROM
                                                    self.smtpSendCommand("MAIL FROM:<\(config.username)>", connection: connection) { _ in
                                                        self.smtpReceive(connection: connection) { _ in
                                                            let recipientGroups = self.buildRecipientGroups(
                                                                to: recipient,
                                                                cc: ccRecipients,
                                                                bcc: bccRecipients
                                                            )
                                                            self.smtpSendRecipients(recipientGroups.all, connection: connection) { rcptResult in
                                                                switch rcptResult {
                                                                case .failure(let error):
                                                                    completion(.failure(error))
                                                                case .success:
                                                                    // DATA
                                                                    self.smtpSendCommand("DATA", connection: connection) { _ in
                                                                        self.smtpReceive(connection: connection) { _ in
                                                                            
                                                                            // Build MIME multipart email with MULTIPLE attachments
                                                                            let boundary = "----=_Part_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                                                                            let dateFormatter = DateFormatter()
                                                                            dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
                                                                            let dateString = dateFormatter.string(from: Date())
                                                                            
                                                                            // Build email lines
                                                                            var emailLines = [
                                                                                "From: \(config.displayName) <\(config.username)>",
                                                                                "To: \(recipientGroups.to)",
                                                                                "Subject: \(subject)",
                                                                                "Date: \(dateString)",
                                                                                "MIME-Version: 1.0",
                                                                                "Content-Type: multipart/mixed; boundary=\"\(boundary)\""
                                                                            ]
                                                                            if !recipientGroups.cc.isEmpty {
                                                                                emailLines.append("Cc: \(recipientGroups.cc.joined(separator: ", "))")
                                                                            }
                                                                            emailLines.append(contentsOf: [
                                                                                "",
                                                                                "--\(boundary)",
                                                                                "Content-Type: text/plain; charset=UTF-8",
                                                                                "Content-Transfer-Encoding: 7bit",
                                                                                "",
                                                                                body,
                                                                                ""
                                                                            ])
                                                                            
                                                                            // Add each attachment as a MIME part
                                                                            for attachment in attachments {
                                                                                let attachmentBase64 = attachment.data.base64EncodedString(options: .lineLength76Characters)
                                                                                emailLines.append(contentsOf: [
                                                                                    "--\(boundary)",
                                                                                    "Content-Type: \(attachment.mimeType); name=\"\(attachment.name)\"",
                                                                                    "Content-Transfer-Encoding: base64",
                                                                                    "Content-Disposition: attachment; filename=\"\(attachment.name)\"",
                                                                                    "",
                                                                                    attachmentBase64,
                                                                                    ""
                                                                                ])
                                                                            }
                                                                            
                                                                            // Close boundary and end message
                                                                            emailLines.append(contentsOf: [
                                                                                "--\(boundary)--",
                                                                                "."
                                                                            ])
                                                                            
                                                                            let emailContent = emailLines.joined(separator: "\r\n")
                                                                            
                                                                            self.smtpSendCommand(emailContent, connection: connection) { _ in
                                                                                self.smtpReceive(connection: connection) { result in
                                                                                    switch result {
                                                                                    case .failure(let error):
                                                                                        completion(.failure(error))
                                                                                    case .success(let dataResponse):
                                                                                        guard dataResponse.hasPrefix("250") else {
                                                                                            completion(.failure(EmailError.sendFailed))
                                                                                            return
                                                                                        }
                                                                                        
                                                                                        // QUIT
                                                                                        self.smtpSendCommand("QUIT", connection: connection) { _ in
                                                                                            completion(.success(true))
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Errors

enum EmailError: LocalizedError {
    case notConfigured
    case connectionFailed
    case authenticationFailed
    case writeFailed
    case readFailed
    case timeout
    case sendFailed
    case attachmentFailed
    case attachmentNotFound
    
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Email is not configured. Please add IMAP/SMTP settings."
        case .connectionFailed: return "Failed to connect to email server."
        case .authenticationFailed: return "Email authentication failed. Check username/password."
        case .writeFailed: return "Failed to send command to server."
        case .readFailed: return "Failed to read from server."
        case .timeout: return "Connection timed out."
        case .sendFailed: return "Failed to send email."
        case .attachmentFailed: return "Failed to read attachment file."
        case .attachmentNotFound: return "Attachment not found in email."
        }
    }
}
