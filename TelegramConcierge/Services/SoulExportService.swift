import Foundation

// MARK: - Soul Export Service

/// Handles exporting and importing all user data for portability
actor SoulExportService {
    static let shared = SoulExportService()
    
    // MARK: - Configuration
    
    /// Version for forward compatibility
    private let exportVersion = "1.0"
    
    /// File extension for soul exports
    static let fileExtension = "soul"
    
    /// Base app folder
    private let appFolder: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    
    // MARK: - Export
    
    /// Export all user data to a ZIP file at the specified destination
    /// - Returns: URL to the exported file
    func exportSoul(to destination: URL) async throws {
        let fm = FileManager.default
        
        // Create a temporary directory for assembly
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        
        // 1. Copy conversation.json
        let conversationSource = appFolder.appendingPathComponent("conversation.json")
        if fm.fileExists(atPath: conversationSource.path) {
            try fm.copyItem(at: conversationSource, to: tempDir.appendingPathComponent("conversation.json"))
        }
        
        // 2. Copy archive folder (chunks)
        let archiveSource = appFolder.appendingPathComponent("archive", isDirectory: true)
        if fm.fileExists(atPath: archiveSource.path) {
            try fm.copyItem(at: archiveSource, to: tempDir.appendingPathComponent("archive", isDirectory: true))
        }
        
        // 3. Copy images folder
        let imagesSource = appFolder.appendingPathComponent("images", isDirectory: true)
        if fm.fileExists(atPath: imagesSource.path) {
            try fm.copyItem(at: imagesSource, to: tempDir.appendingPathComponent("images", isDirectory: true))
        }
        
        // 4. Copy documents folder
        let documentsSource = appFolder.appendingPathComponent("documents", isDirectory: true)
        if fm.fileExists(atPath: documentsSource.path) {
            try fm.copyItem(at: documentsSource, to: tempDir.appendingPathComponent("documents", isDirectory: true))
        }
        
        // 5. Copy contacts.json
        let contactsSource = appFolder.appendingPathComponent("contacts.json")
        if fm.fileExists(atPath: contactsSource.path) {
            try fm.copyItem(at: contactsSource, to: tempDir.appendingPathComponent("contacts.json"))
        }
        
        // 6. Copy reminders.json
        let remindersSource = appFolder.appendingPathComponent("reminders.json")
        if fm.fileExists(atPath: remindersSource.path) {
            try fm.copyItem(at: remindersSource, to: tempDir.appendingPathComponent("reminders.json"))
        }
        
        // 7. Copy calendar.json
        let calendarSource = appFolder.appendingPathComponent("calendar.json")
        if fm.fileExists(atPath: calendarSource.path) {
            try fm.copyItem(at: calendarSource, to: tempDir.appendingPathComponent("calendar.json"))
        }
        
        // 8. Create soul_config.json with Keychain and UserDefaults data
        let config = buildSoulConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let configData = try encoder.encode(config)
        try configData.write(to: tempDir.appendingPathComponent("soul_config.json"))
        
        // 8. Create ZIP archive using native macOS zip command
        // Remove existing file if present
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        
        try await createZipArchive(from: tempDir, to: destination)
        
        print("[SoulExportService] Exported soul to: \(destination.path)")
    }
    
    // MARK: - Import
    
    /// Import user data from a soul file
    /// - Parameter source: URL to the .soul file
    func importSoul(from source: URL) async throws {
        let fm = FileManager.default
        
        // Create a temporary directory for extraction
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        
        // Extract ZIP using native macOS unzip command
        try await extractZipArchive(from: source, to: tempDir)
        
        // 1. Restore conversation.json
        let conversationSource = tempDir.appendingPathComponent("conversation.json")
        let conversationDest = appFolder.appendingPathComponent("conversation.json")
        if fm.fileExists(atPath: conversationSource.path) {
            try? fm.removeItem(at: conversationDest)
            try fm.copyItem(at: conversationSource, to: conversationDest)
        }
        
        // 2. Restore archive folder
        let archiveSource = tempDir.appendingPathComponent("archive", isDirectory: true)
        let archiveDest = appFolder.appendingPathComponent("archive", isDirectory: true)
        if fm.fileExists(atPath: archiveSource.path) {
            try? fm.removeItem(at: archiveDest)
            try fm.copyItem(at: archiveSource, to: archiveDest)
        }
        
        // 3. Restore images folder
        let imagesSource = tempDir.appendingPathComponent("images", isDirectory: true)
        let imagesDest = appFolder.appendingPathComponent("images", isDirectory: true)
        if fm.fileExists(atPath: imagesSource.path) {
            try? fm.removeItem(at: imagesDest)
            try fm.copyItem(at: imagesSource, to: imagesDest)
        }
        
        // 4. Restore documents folder
        let documentsSource = tempDir.appendingPathComponent("documents", isDirectory: true)
        let documentsDest = appFolder.appendingPathComponent("documents", isDirectory: true)
        if fm.fileExists(atPath: documentsSource.path) {
            try? fm.removeItem(at: documentsDest)
            try fm.copyItem(at: documentsSource, to: documentsDest)
        }
        
        // 5. Restore contacts.json
        let contactsSource = tempDir.appendingPathComponent("contacts.json")
        let contactsDest = appFolder.appendingPathComponent("contacts.json")
        if fm.fileExists(atPath: contactsSource.path) {
            try? fm.removeItem(at: contactsDest)
            try fm.copyItem(at: contactsSource, to: contactsDest)
        }
        
        // 6. Restore reminders.json
        let remindersSource = tempDir.appendingPathComponent("reminders.json")
        let remindersDest = appFolder.appendingPathComponent("reminders.json")
        if fm.fileExists(atPath: remindersSource.path) {
            try? fm.removeItem(at: remindersDest)
            try fm.copyItem(at: remindersSource, to: remindersDest)
        }
        
        // 7. Restore calendar.json
        let calendarSource = tempDir.appendingPathComponent("calendar.json")
        let calendarDest = appFolder.appendingPathComponent("calendar.json")
        if fm.fileExists(atPath: calendarSource.path) {
            try? fm.removeItem(at: calendarDest)
            try fm.copyItem(at: calendarSource, to: calendarDest)
        }
        
        // 8. Restore soul_config.json settings
        let configSource = tempDir.appendingPathComponent("soul_config.json")
        if fm.fileExists(atPath: configSource.path) {
            let configData = try Data(contentsOf: configSource)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let config = try decoder.decode(SoulConfig.self, from: configData)
            try restoreSoulConfig(config)
        }
        
        print("[SoulExportService] Imported soul from: \(source.path)")
    }
    
    // MARK: - ZIP Operations (using native macOS commands)
    
    private func createZipArchive(from sourceDir: URL, to destination: URL) async throws {
        let fm = FileManager.default
        
        // Create zip in temp directory first, then copy to destination
        // This works around sandboxing: the subprocess can't write directly to user-selected paths
        let tempZip = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: tempZip) }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = sourceDir
        process.arguments = ["-r", "-q", tempZip.path, "."]
        
        let pipe = Pipe()
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw SoulExportError.zipFailed(errorMessage)
        }
        
        // Copy from temp to destination (this uses the security-scoped access granted by NSSavePanel)
        try fm.copyItem(at: tempZip, to: destination)
    }
    
    private func extractZipArchive(from source: URL, to destinationDir: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", source.path, "-d", destinationDir.path]
        
        let pipe = Pipe()
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw SoulExportError.unzipFailed(errorMessage)
        }
    }
    
    // MARK: - Soul Config
    
    private struct SoulConfig: Codable {
        let version: String
        let exportDate: Date
        let persona: PersonaConfig
        let fileDescriptions: [String: String]
    }
    
    private struct PersonaConfig: Codable {
        let assistantName: String?
        let userName: String?
        let userContext: String?
        let structuredUserContext: String?
    }
    
    private func buildSoulConfig() -> SoulConfig {
        // Load persona settings from Keychain
        let persona = PersonaConfig(
            assistantName: KeychainHelper.load(key: KeychainHelper.assistantNameKey),
            userName: KeychainHelper.load(key: KeychainHelper.userNameKey),
            userContext: KeychainHelper.load(key: KeychainHelper.userContextKey),
            structuredUserContext: KeychainHelper.load(key: KeychainHelper.structuredUserContextKey)
        )
        
        // Load file descriptions from UserDefaults
        var fileDescriptions: [String: String] = [:]
        if let data = UserDefaults.standard.data(forKey: "FileDescriptions"),
           let descriptions = try? JSONDecoder().decode([String: String].self, from: data) {
            fileDescriptions = descriptions
        }
        
        return SoulConfig(
            version: exportVersion,
            exportDate: Date(),
            persona: persona,
            fileDescriptions: fileDescriptions
        )
    }
    
    private func restoreSoulConfig(_ config: SoulConfig) throws {
        // Restore persona settings to Keychain
        if let assistantName = config.persona.assistantName {
            try KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: assistantName)
        }
        if let userName = config.persona.userName {
            try KeychainHelper.save(key: KeychainHelper.userNameKey, value: userName)
        }
        if let userContext = config.persona.userContext {
            try KeychainHelper.save(key: KeychainHelper.userContextKey, value: userContext)
        }
        if let structuredUserContext = config.persona.structuredUserContext {
            try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: structuredUserContext)
        }
        
        // Restore file descriptions to UserDefaults
        if !config.fileDescriptions.isEmpty {
            if let data = try? JSONEncoder().encode(config.fileDescriptions) {
                UserDefaults.standard.set(data, forKey: "FileDescriptions")
            }
        }
    }
}

// MARK: - Errors

enum SoulExportError: LocalizedError {
    case zipFailed(String)
    case unzipFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .zipFailed(let message):
            return "Failed to create archive: \(message)"
        case .unzipFailed(let message):
            return "Failed to extract archive: \(message)"
        }
    }
}
