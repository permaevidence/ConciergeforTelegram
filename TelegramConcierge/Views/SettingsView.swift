import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    
    @State private var telegramToken: String = ""
    @State private var chatId: String = ""
    @State private var openRouterApiKey: String = ""
    @State private var openRouterModel: String = ""
    @State private var openRouterProviders: String = ""
    @State private var openRouterReasoningEffort: String = "high"
    @State private var serperApiKey: String = ""
    @State private var jinaApiKey: String = ""
    @State private var showingSaveConfirmation: Bool = false
    @State private var isTesting: Bool = false
    @State private var botInfo: String?
    @State private var testError: String?
    
    // Email settings
    @State private var imapHost: String = ""
    @State private var imapPort: String = "993"
    @State private var smtpHost: String = ""
    @State private var smtpPort: String = "465"
    @State private var emailUsername: String = ""
    @State private var emailPassword: String = ""
    @State private var emailDisplayName: String = ""
    @State private var isTestingEmail: Bool = false
    @State private var emailTestSuccess: String?
    @State private var emailTestError: String?
    
    // Gmail API settings
    @State private var emailMode: String = "imap"  // "imap" or "gmail"
    @State private var gmailClientId: String = ""
    @State private var gmailClientSecret: String = ""
    @State private var isAuthenticatingGmail: Bool = false
    @State private var gmailAuthStatus: String = ""
    
    // Contacts settings
    @State private var showingVCardPicker: Bool = false
    @State private var contactCount: Int = 0
    @State private var contactImportSuccess: String?
    @State private var contactImportError: String?
    
    // Image generation settings
    @State private var geminiApiKey: String = ""
    
    // Code CLI settings
    @State private var codeCLIProvider: String = KeychainHelper.defaultCodeCLIProvider
    @State private var claudeCodeCommand: String = "claude"
    @State private var claudeCodeArgs: String = KeychainHelper.defaultClaudeCodeArgs
    @State private var claudeCodeTimeout: String = KeychainHelper.defaultClaudeCodeTimeout
    @State private var geminiCodeCommand: String = KeychainHelper.defaultGeminiCodeCommand
    @State private var geminiCodeArgs: String = KeychainHelper.defaultGeminiCodeArgs
    @State private var geminiCodeTimeout: String = KeychainHelper.defaultGeminiCodeTimeout
    @State private var claudeCodeDisableLegacyDocumentGenerationTools: Bool = false
    
    // Vercel deployment settings
    @State private var vercelApiToken: String = ""
    @State private var vercelTeamScope: String = ""
    @State private var vercelProjectName: String = ""
    @State private var vercelCommand: String = KeychainHelper.defaultVercelCommand
    @State private var vercelTimeout: String = KeychainHelper.defaultVercelTimeout
    
    // Instant database settings
    @State private var instantApiToken: String = ""
    @State private var instantCLICommand: String = KeychainHelper.defaultInstantCLICommand
    
    // Persona settings
    @State private var assistantName: String = ""
    @State private var userName: String = ""
    @State private var userContext: String = ""
    @State private var structuredUserContext: String = ""
    @State private var isStructuredContextExpanded: Bool = false
    @State private var isEditingStructuredContext: Bool = false
    @State private var structuredContextDraft: String = ""
    @State private var isStructuring: Bool = false
    @State private var structuringError: String?
    
    // Section save confirmations
    @State private var savedSection: String?
    
    // Context viewer
    @State private var showingContextViewer: Bool = false
    
    // Archive settings
    @State private var archiveChunkSize: String = ""
    
    // Memory deletion
    @State private var showingDeleteMemoryConfirmation: Bool = false
    @State private var showingDeleteContextConfirmation: Bool = false
    @State private var showingChunkSizeSaved: Bool = false
    
    // Mind export/import
    @State private var isExportingMind: Bool = false
    @State private var isImportingMind: Bool = false
    @State private var mindExportSuccess: String?
    @State private var mindExportError: String?
    @State private var showingRestoreConfirmation: Bool = false
    @State private var pendingImportURL: URL?
    @State private var showingMindFilePicker: Bool = false
    
    // Clear contacts
    @State private var showingClearContactsConfirmation: Bool = false
    
    // Calendar export/import
    @State private var isExportingCalendar: Bool = false
    @State private var isImportingCalendar: Bool = false
    @State private var calendarExportSuccess: String?
    @State private var calendarExportError: String?
    @State private var showingCalendarFilePicker: Bool = false
    @State private var calendarEventCount: Int = 0
    
    private let telegramService = TelegramBotService()
    private let defaultArchiveChunkSize = 10000
    private let minimumArchiveChunkSize = 5000
    
    private var activeArchiveChunkSize: Int {
        if let savedChunkSize = KeychainHelper.load(key: KeychainHelper.archiveChunkSizeKey),
           let chunkValue = Int(savedChunkSize),
           chunkValue >= minimumArchiveChunkSize {
            return chunkValue
        }
        return defaultArchiveChunkSize
    }
    
    var body: some View {
        Form {
            // MARK: - Persona Section
            Section {
                personaSettingsContent
            } header: {
                Label("Persona", systemImage: "person.text.rectangle")
            }
            
            Section {
                SecureField("Bot Token", text: $telegramToken)
                    .textFieldStyle(.roundedBorder)
                
                TextField("Chat ID", text: $chatId)
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Text("Get this from @BotFather on Telegram")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button("Test") {
                        testConnection()
                    }
                    .buttonStyle(.bordered)
                    .disabled(telegramToken.isEmpty || isTesting)
                }
                
                Text("Your Telegram user ID. Send /start to @userinfobot to get it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if isTesting {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Testing connection...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let info = botInfo {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(info)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                if let error = testError {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                sectionSaveButton("telegram") {
                    saveTelegramSection()
                }
            } header: {
                Label("Telegram Bot", systemImage: "paperplane.fill")
            }
            
            Section {
                SecureField("API Key", text: $openRouterApiKey)
                    .textFieldStyle(.roundedBorder)
                
                Text("Get your API key from openrouter.ai")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("Model", text: $openRouterModel)
                    .textFieldStyle(.roundedBorder)
                
                Text("Default: google/gemini-3-flash-preview")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("Preferred Providers", text: $openRouterProviders)
                    .textFieldStyle(.roundedBorder)
                
                Text("Comma-separated list (e.g., google, anthropic). Leave empty to allow all.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Picker("Reasoning Effort", selection: $openRouterReasoningEffort) {
                    Text("Not Specified").tag("")
                    Text("Minimal").tag("minimal")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .pickerStyle(.menu)
                
                Text("Controls thinking depth for supported models (Gemini 3, o1/o3, Grok).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                sectionSaveButton("openrouter") {
                    saveOpenRouterSection()
                }
            } header: {
                Label("OpenRouter", systemImage: "brain.head.profile")
            }
            
            Section {
                SecureField("Serper API Key", text: $serperApiKey)
                    .textFieldStyle(.roundedBorder)
                
                Text("For Google search. Get from serper.dev (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                SecureField("Jina API Key", text: $jinaApiKey)
                    .textFieldStyle(.roundedBorder)
                
                Text("For web scraping. Get from jina.ai (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                sectionSaveButton("websearch") {
                    saveWebSearchSection()
                }
            } header: {
                Label("Web Search Tool", systemImage: "magnifyingglass")
            }
            
            Section {
                SecureField("Gemini API Key", text: $geminiApiKey)
                    .textFieldStyle(.roundedBorder)
                
                Link("Get your API key from Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.caption)
                
                Text("Enables AI image generation. Uses gemini-3-pro-image-preview model.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                sectionSaveButton("imagegen") {
                    saveImageGenSection()
                }
            } header: {
                Label("Image Generation", systemImage: "photo.badge.plus")
            }
            
            Section {
                Toggle(
                    "Use Gemini CLI instead of Claude Code",
                    isOn: Binding(
                        get: { codeCLIProvider == "gemini" },
                        set: { codeCLIProvider = $0 ? "gemini" : "claude" }
                    )
                )
                
                Text("Active provider: \(codeCLIProvider == "gemini" ? "Gemini CLI" : "Claude Code")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if codeCLIProvider == "gemini" {
                    TextField("CLI Command", text: $geminiCodeCommand)
                        .textFieldStyle(.roundedBorder)
                    
                    Text("Default: \(KeychainHelper.defaultGeminiCodeCommand)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextField("Default CLI Args", text: $geminiCodeArgs)
                        .textFieldStyle(.roundedBorder)
                    
                    Text("Default: \(KeychainHelper.defaultGeminiCodeArgs). You can override per tool call.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextField("Default Timeout (seconds)", text: $geminiCodeTimeout)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField("CLI Command", text: $claudeCodeCommand)
                        .textFieldStyle(.roundedBorder)
                    
                    Text("Default: claude")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextField("Default CLI Args", text: $claudeCodeArgs)
                        .textFieldStyle(.roundedBorder)
                    
                    Text("Default: \(KeychainHelper.defaultClaudeCodeArgs). You can override per tool call.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextField("Default Timeout (seconds)", text: $claudeCodeTimeout)
                        .textFieldStyle(.roundedBorder)
                }
                
                Text("Used by run_claude_code when timeout_seconds is omitted. Range: 30-3600.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Toggle("Use selected Code CLI for document generation", isOn: $claudeCodeDisableLegacyDocumentGenerationTools)
                
                Text("When enabled, Gemini will not see the legacy generate_document tool and will use project tools powered by the selected Code CLI provider.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                sectionSaveButton("claudecode") {
                    saveClaudeCodeSection()
                }
                
            } header: {
                Label("Code CLI", systemImage: "terminal")
            }
            
            Section {
                SecureField("Vercel API Token", text: $vercelApiToken)
                    .textFieldStyle(.roundedBorder)
                
                Text("Create a token in Vercel Dashboard > Settings > Tokens. Required for deploy_project_to_vercel.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("Default Team Scope (optional)", text: $vercelTeamScope)
                    .textFieldStyle(.roundedBorder)
                
                Text("Your Vercel team/account scope slug. Used when deploy tool doesn't pass team_scope.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("Default Project Name (optional)", text: $vercelProjectName)
                    .textFieldStyle(.roundedBorder)
                
                Text("Used for automatic `vercel link` before deploy when project_name is omitted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("CLI Command", text: $vercelCommand)
                    .textFieldStyle(.roundedBorder)
                
                Text("Default: \(KeychainHelper.defaultVercelCommand)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("Default Timeout (seconds)", text: $vercelTimeout)
                    .textFieldStyle(.roundedBorder)
                
                Text("Used by deploy_project_to_vercel when timeout_seconds is omitted. Range: 60-3600.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Link("Install Vercel CLI", destination: URL(string: "https://vercel.com/docs/cli")!)
                    .font(.caption)
                
                sectionSaveButton("vercel") {
                    saveVercelSection()
                }
            } header: {
                Label("Vercel Deployment", systemImage: "icloud.and.arrow.up")
            }
            
            Section {
                SecureField("Instant CLI Auth Token", text: $instantApiToken)
                    .textFieldStyle(.roundedBorder)
                
                Text("Used by provision/push database tools. Run `npx instant-cli login` to get your CLI auth token.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("Instant CLI Command", text: $instantCLICommand)
                    .textFieldStyle(.roundedBorder)
                
                Text("Default: \(KeychainHelper.defaultInstantCLICommand)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Link("Instant CLI Docs", destination: URL(string: "https://www.instantdb.com/docs/cli")!)
                    .font(.caption)
                
                sectionSaveButton("instantdb") {
                    saveInstantDatabaseSection()
                }
            } header: {
                Label("Instant Database", systemImage: "externaldrive.badge.icloud")
            }
            
            // MARK: - Email Settings Section
            Section {
                emailSettingsContent
            } header: {
                Label("Email (IMAP/SMTP)", systemImage: "envelope.fill")
            }
            
            // MARK: - Voice Transcription Section
            Section {
                voiceTranscriptionContent
            } header: {
                Label("Voice Transcription", systemImage: "waveform")
            }
            
            Section {
                HStack {
                    Spacer()
                    
                    Button("Save & Start Bot") {
                        saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isFormValid)
                    
                    Spacer()
                }
            }
            
            if showingSaveConfirmation {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Settings saved! Bot is now active.")
                            .foregroundColor(.green)
                    }
                }
            }
            
            if let error = conversationManager.error {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            
            // MARK: - Developer Tools Section
            Section {
                Button {
                    showingContextViewer = true
                } label: {
                    HStack {
                        Image(systemName: "brain")
                            .foregroundColor(.purple)
                        Text("View Gemini Context")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                Text("See all context currently being sent to Gemini: conversation, chunks, user context, calendar, and email.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Divider()
                
                HStack {
                    Text("Archive Chunk Size")
                    Spacer()
                    TextField("\(activeArchiveChunkSize)", text: $archiveChunkSize)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            saveArchiveChunkSize()
                        }
                    Text("tokens")
                        .foregroundColor(.secondary)
                    if showingChunkSizeSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .transition(.opacity)
                    }
                }
                
                Text("Size of each memory chunk. Archival triggers at 2× this value. Consolidation merges 4 chunks. Min: 5,000. If left empty, the default value is used. Changes apply to new chunks only.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
            } header: {
                Label("Developer Tools", systemImage: "wrench.and.screwdriver")
            }
            
            // MARK: - Data Section
            Section {
                // MARK: Data Portability
                VStack(alignment: .leading, spacing: 4) {
                    Text("Data Portability")
                        .font(.body)
                    Text("Export or restore your entire assistant memory")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 12) {
                    Button {
                        exportMind()
                    } label: {
                        HStack {
                            if isExportingMind {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.down.doc")
                            }
                            Text("Download Mind")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExportingMind || isImportingMind)
                    
                    Button {
                        print("[SettingsView] Restore Mind button tapped, opening NSOpenPanel")
                        Task {
                            let openPanel = NSOpenPanel()
                            openPanel.allowedContentTypes = [.item]
                            openPanel.allowsMultipleSelection = false
                            openPanel.canChooseDirectories = false
                            openPanel.title = "Select Mind Backup"
                            openPanel.message = "Choose a .mind file to restore"
                            
                            let response = await openPanel.beginSheetModal(for: NSApp.mainWindow ?? NSWindow())
                            
                            guard response == .OK, let url = openPanel.url else {
                                return
                            }
                            
                            // Copy to temp location
                            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                            try? FileManager.default.removeItem(at: tempURL)
                            do {
                                try FileManager.default.copyItem(at: url, to: tempURL)
                                await MainActor.run {
                                    pendingImportURL = tempURL
                                    showingRestoreConfirmation = true
                                }
                            } catch {
                                await MainActor.run {
                                    mindExportError = "Failed to read file: \(error.localizedDescription)"
                                }
                            }
                        }
                    } label: {
                        HStack {
                            if isImportingMind {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.up.doc")
                            }
                            Text("Restore Mind")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExportingMind || isImportingMind)
                }
                
                if let success = mindExportSuccess {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(success)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                if let error = mindExportError {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                Text("Download Mind exports your conversation history, memory chunks, files, contacts, reminders, calendar, and persona settings. API keys are NOT included for security.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Divider()
                
                contactsSettingsContent
                
                Divider()
                
                // Calendar Export/Import
                VStack(alignment: .leading, spacing: 4) {
                    Text("Calendar")
                        .font(.body)
                    Text("\(calendarEventCount) event\(calendarEventCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 12) {
                    Button(action: { exportCalendar() }) {
                        HStack {
                            if isExportingCalendar {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.down.doc")
                            }
                            Text("Download")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExportingCalendar || isImportingCalendar || calendarEventCount == 0)
                    
                    Button(action: { showingCalendarFilePicker = true }) {
                        HStack {
                            if isImportingCalendar {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.up.doc")
                            }
                            Text("Upload")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isExportingCalendar || isImportingCalendar)
                }
                
                if let success = calendarExportSuccess {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(success)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                if let error = calendarExportError {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                Text("Export or import your calendar events separately. The calendar is also included in Mind exports.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Divider()
                
                Button {
                    showingDeleteMemoryConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                        Text("Delete Memory")
                            .foregroundColor(.red)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                
                Text("Permanently deletes all conversation history, chunks, summaries, user context, and reminders. Calendar and contacts are preserved.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("Data", systemImage: "externaldrive.fill")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 450, height: 750)
        .onAppear {
            loadSettings()
            // Always refresh user context from Keychain (Gemini may have changed it via tools)
            structuredUserContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
            structuredContextDraft = structuredUserContext
            Task {
                await WhisperKitService.shared.checkModelStatus()
                calendarEventCount = await CalendarService.shared.totalEventCount()
            }
        }
        .onChange(of: structuredUserContext) { newValue in
            if !isEditingStructuredContext {
                structuredContextDraft = newValue
            }
        }
        .sheet(isPresented: $showingContextViewer) {
            ContextViewerView()
                .environmentObject(conversationManager)
        }
        .alert("Delete All Memory?", isPresented: $showingDeleteMemoryConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await conversationManager.deleteAllMemory()
                    // Clear local state to reflect deletion
                    userContext = ""
                    structuredUserContext = ""
                    structuredContextDraft = ""
                    isEditingStructuredContext = false
                }
            }
        } message: {
            Text("This will permanently delete all conversation history, archived chunks, summaries, user context, and reminders. Calendar and contacts will be preserved. This action cannot be undone.")
        }
        .fileImporter(
            isPresented: $showingMindFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else {
                    mindExportError = "Unable to access file"
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                
                // Copy to temp location since security-scoped access may expire
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: tempURL)
                do {
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    pendingImportURL = tempURL
                    showingRestoreConfirmation = true
                } catch {
                    mindExportError = "Failed to read file: \(error.localizedDescription)"
                }
                
            case .failure(let error):
                mindExportError = "Failed to select file: \(error.localizedDescription)"
            }
        }
        .alert("Restore Mind?", isPresented: $showingRestoreConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
            }
            Button("Restore", role: .destructive) {
                if let url = pendingImportURL {
                    importMind(from: url)
                }
            }
        } message: {
            Text("This will replace all your current data with the imported mind. Your existing conversation, files, and settings will be overwritten. This cannot be undone.")
        }
        .fileImporter(
            isPresented: $showingCalendarFilePicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else {
                    calendarExportError = "Unable to access file"
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                
                importCalendar(from: url)
                
            case .failure(let error):
                calendarExportError = "Failed to select file: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Voice Transcription Content
    
    @ViewBuilder
    private var voiceTranscriptionContent: some View {
        let whisper = WhisperKitService.shared
        
        HStack {
            // Status icon
            Group {
                if whisper.isModelReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if whisper.isDownloading || whisper.isCompiling || whisper.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.secondary)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Whisper Model")
                    .font(.body)
                Text(whisper.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Action buttons
            if !whisper.hasModelOnDisk && !whisper.isDownloading {
                Button("Download") {
                    Task {
                        await whisper.startDownload()
                    }
                }
                .buttonStyle(.bordered)
            } else if whisper.hasModelOnDisk && !whisper.isModelReady && !whisper.isCompiling && !whisper.isLoading {
                Button("Compile") {
                    Task {
                        await whisper.loadModel()
                    }
                }
                .buttonStyle(.bordered)
            } else if whisper.isModelReady {
                Button("Delete") {
                    try? whisper.deleteModelFromDisk()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
        
        // Download progress bar
        if whisper.isDownloading {
            ProgressView(value: Double(whisper.downloadProgress))
                .progressViewStyle(.linear)
        }
        
        Text("The Whisper model enables voice message transcription from Telegram.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    
    // MARK: - Persona Settings Content
    
    @ViewBuilder
    private var personaSettingsContent: some View {
        TextField("Assistant Name", text: $assistantName)
            .textFieldStyle(.roundedBorder)
        
        Text("What should the AI call itself? (e.g., Jarvis, Friday)")
            .font(.caption)
            .foregroundColor(.secondary)
        
        TextField("Your Name", text: $userName)
            .textFieldStyle(.roundedBorder)
        
        Text("Your name for personalized responses")
            .font(.caption)
            .foregroundColor(.secondary)
        
        sectionSaveButton("persona") {
            savePersonaSection()
        }
        
        VStack(alignment: .leading, spacing: 4) {
            Text(structuredUserContext.isEmpty ? "About You" : "Update About You")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextEditor(text: $userContext)
                .frame(height: 80)
                .font(.body)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
        
        Text(structuredUserContext.isEmpty
             ? "Tell the AI about yourself: job, preferences, location, communication style, etc."
             : "Add new details or corrections here — they'll be merged into your existing structured context, not replace it.")
            .font(.caption)
            .foregroundColor(.secondary)
        
        HStack {
            Button("Process & Save") {
                structureUserContext()
            }
            .buttonStyle(.bordered)
            .disabled(userContext.isEmpty || openRouterApiKey.isEmpty || isStructuring)
            
            if !structuredUserContext.isEmpty {
                Button(isEditingStructuredContext ? "Editing..." : "Edit Context") {
                    beginStructuredContextEdit()
                }
                .buttonStyle(.bordered)
                .disabled(isEditingStructuredContext)

                Button("Delete Context") {
                    showingDeleteContextConfirmation = true
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
            
            if isStructuring {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .alert("Delete Context About You?", isPresented: $showingDeleteContextConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                structuredUserContext = ""
                structuredContextDraft = ""
                userContext = ""
                isEditingStructuredContext = false
                try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: "")
                try? KeychainHelper.save(key: KeychainHelper.userContextKey, value: "")
            }
        } message: {
            Text("This will delete your structured context so you can start fresh. This cannot be undone.")
        }
        
        if let error = structuringError {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        
        if !structuredUserContext.isEmpty {
            DisclosureGroup(isExpanded: $isStructuredContextExpanded) {
                if isEditingStructuredContext {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $structuredContextDraft)
                            .frame(minHeight: 140)
                            .font(.body)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )

                        HStack {
                            Button("Save Changes") {
                                saveStructuredContextEdits()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(structuredContextDraft == structuredUserContext)

                            Button("Cancel") {
                                cancelStructuredContextEdit()
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }
                    }
                } else {
                    Text(structuredUserContext)
                        .font(.caption)
                        .padding(8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(5)
                }
            } label: {
                Text("User Context (used in prompts):")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Contacts Settings Content
    
    @ViewBuilder
    private var contactsSettingsContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Contact List")
                .font(.body)
            Text("\(contactCount) contacts stored")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button("Import vCard") {
                    showingVCardPicker = true
                }
                .buttonStyle(.bordered)
                
                Button("Clear") {
                    showingClearContactsConfirmation = true
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
                .disabled(contactCount == 0)
            }
        }
        .alert("Clear All Contacts?", isPresented: $showingClearContactsConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                Task {
                    await ContactsService.shared.clearAllContacts()
                    contactCount = 0
                }
            }
        } message: {
            Text("This will permanently delete all \(contactCount) contacts. This action cannot be undone.")
        }
        .onAppear {
            Task {
                contactCount = await ContactsService.shared.contactCount()
            }
        }
        .fileImporter(
            isPresented: $showingVCardPicker,
            allowedContentTypes: [UTType.vCard],
            allowsMultipleSelection: false
        ) { result in
            contactImportSuccess = nil
            contactImportError = nil
            
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                
                // Request access to security-scoped resource
                guard url.startAccessingSecurityScopedResource() else {
                    contactImportError = "Unable to access file"
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                
                Task {
                    do {
                        let data = try Data(contentsOf: url)
                        let imported = await ContactsService.shared.importFromVCard(data: data)
                        await MainActor.run {
                            if imported > 0 {
                                contactImportSuccess = "Imported \(imported) contact(s)"
                                contactCount = imported + (contactCount - 0) // Refresh count
                            } else {
                                contactImportError = "No contacts found in file"
                            }
                        }
                        // Refresh actual count
                        let newCount = await ContactsService.shared.contactCount()
                        await MainActor.run {
                            contactCount = newCount
                        }
                    } catch {
                        await MainActor.run {
                            contactImportError = "Failed to read file: \(error.localizedDescription)"
                        }
                    }
                }
                
            case .failure(let error):
                contactImportError = "Failed to select file: \(error.localizedDescription)"
            }
        }
        
        if let success = contactImportSuccess {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(success)
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        
        if let error = contactImportError {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        
        Text("Import contacts from a vCard (.vcf) file. Gemini can then look up contacts by name when sending emails.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    
    // MARK: - Email Settings Content
    
    @ViewBuilder
    private var emailSettingsContent: some View {
        // Gmail API is the primary option, IMAP is secondary
        HStack {
            Text(emailMode == "gmail" ? "Gmail API" : "IMAP/SMTP")
                .font(.headline)
            
            Spacer()
            
            if emailMode == "gmail" {
                Button(action: {
                    emailMode = "imap"
                    try? KeychainHelper.save(key: KeychainHelper.emailModeKey, value: "imap")
                }) {
                    Text("Use IMAP instead")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    emailMode = "gmail"
                    try? KeychainHelper.save(key: KeychainHelper.emailModeKey, value: "gmail")
                }) {
                    Text("Use Gmail API")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        
        if emailMode == "imap" {
            // IMAP Settings
            TextField("IMAP Host", text: $imapHost)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                TextField("IMAP Port", text: $imapPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                
                Text("Default: 993 for SSL")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            TextField("SMTP Host", text: $smtpHost)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                TextField("SMTP Port", text: $smtpPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                
                Text("Use port 465 for SSL (required)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            TextField("Email Username", text: $emailUsername)
                .textFieldStyle(.roundedBorder)
            
            SecureField("Email Password / App Password", text: $emailPassword)
                .textFieldStyle(.roundedBorder)
            
            TextField("Display Name (optional)", text: $emailDisplayName)
                .textFieldStyle(.roundedBorder)
            
            // Gmail quick-fill button
            HStack {
                Button("Use Gmail Defaults") {
                    imapHost = "imap.gmail.com"
                    imapPort = "993"
                    smtpHost = "smtp.gmail.com"
                    smtpPort = "465"
                }
                .buttonStyle(.bordered)
                .font(.caption)
                
                Spacer()
                
                Button("Test IMAP") {
                    testEmailConnection(testSMTP: false)
                }
                .buttonStyle(.bordered)
                .disabled(imapHost.isEmpty || emailUsername.isEmpty || emailPassword.isEmpty || isTestingEmail)
                
                Button("Test SMTP") {
                    testEmailConnection(testSMTP: true)
                }
                .buttonStyle(.bordered)
                .disabled(smtpHost.isEmpty || emailUsername.isEmpty || emailPassword.isEmpty || isTestingEmail)
            }
            
            // Gmail App Password instructions
            VStack(alignment: .leading, spacing: 4) {
                Text("**Gmail requires an App Password** (16-digit code):")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("1. Go to myaccount.google.com → Security → 2-Step Verification")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("2. Scroll to 'App passwords' → Generate for 'Mail'")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("3. Paste the 16-character code above (no spaces needed)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Link("Open Google App Passwords", destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                    .font(.caption)
            }
        } else {
            // Gmail API Settings
            VStack(alignment: .leading, spacing: 8) {
                Text("Gmail API requires a Google Cloud project with OAuth credentials.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Link("Setup instructions", destination: URL(string: "https://console.cloud.google.com/")!)
                    .font(.caption)
            }
            
            SecureField("Client ID", text: $gmailClientId)
                .textFieldStyle(.roundedBorder)
            
            SecureField("Client Secret", text: $gmailClientSecret)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Button(isAuthenticatingGmail ? "Authenticating..." : "Authenticate with Google") {
                    authenticateGmail()
                }
                .buttonStyle(.borderedProminent)
                .disabled(gmailClientId.isEmpty || gmailClientSecret.isEmpty || isAuthenticatingGmail)
                
                if !gmailAuthStatus.isEmpty {
                    HStack {
                        Image(systemName: gmailAuthStatus.contains("✓") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundColor(gmailAuthStatus.contains("✓") ? .green : .orange)
                        Text(gmailAuthStatus)
                            .font(.caption)
                            .foregroundColor(gmailAuthStatus.contains("✓") ? .green : .orange)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("**Benefits of Gmail API:**")
                    .font(.caption)
                    .fontWeight(.semibold)
                
                Text("• Faster email operations")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("• Native thread support")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("• Fewer tools for better AI performance (5 vs 8)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        
        if isTestingEmail {
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Testing connection...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        
        if let successMessage = emailTestSuccess {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(successMessage)
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        
        if let error = emailTestError {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        
        sectionSaveButton("email") {
            saveEmailSection()
        }
    }
    
    private var isFormValid: Bool {
        !telegramToken.isEmpty && !chatId.isEmpty && !openRouterApiKey.isEmpty
    }
    
    private func loadSettings() {
        telegramToken = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) ?? ""
        chatId = KeychainHelper.load(key: KeychainHelper.telegramChatIdKey) ?? ""
        openRouterApiKey = KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? ""
        openRouterModel = KeychainHelper.load(key: KeychainHelper.openRouterModelKey) ?? ""
        openRouterProviders = KeychainHelper.load(key: KeychainHelper.openRouterProvidersKey) ?? ""
        openRouterReasoningEffort = KeychainHelper.load(key: KeychainHelper.openRouterReasoningEffortKey) ?? "high"
        serperApiKey = KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) ?? ""
        jinaApiKey = KeychainHelper.load(key: KeychainHelper.jinaApiKeyKey) ?? ""
        
        // Load email settings
        imapHost = KeychainHelper.load(key: KeychainHelper.imapHostKey) ?? ""
        imapPort = KeychainHelper.load(key: KeychainHelper.imapPortKey) ?? "993"
        smtpHost = KeychainHelper.load(key: KeychainHelper.smtpHostKey) ?? ""
        smtpPort = KeychainHelper.load(key: KeychainHelper.smtpPortKey) ?? "465"
        emailUsername = KeychainHelper.load(key: KeychainHelper.imapUsernameKey) ?? ""
        emailPassword = KeychainHelper.load(key: KeychainHelper.imapPasswordKey) ?? ""
        emailDisplayName = KeychainHelper.load(key: KeychainHelper.emailDisplayNameKey) ?? ""
        
        // Load Gmail API settings
        emailMode = KeychainHelper.load(key: KeychainHelper.emailModeKey) ?? "gmail"
        gmailClientId = KeychainHelper.load(key: KeychainHelper.gmailClientIdKey) ?? ""
        gmailClientSecret = KeychainHelper.load(key: KeychainHelper.gmailClientSecretKey) ?? ""
        
        // Check Gmail auth status
        Task {
            let isAuthenticated = await GmailService.shared.isAuthenticated
            await MainActor.run {
                if emailMode == "gmail" && isAuthenticated {
                    gmailAuthStatus = "Authenticated ✓"
                } else if emailMode == "gmail" && !gmailClientId.isEmpty && !gmailClientSecret.isEmpty {
                    gmailAuthStatus = "Not authenticated"
                }
            }
        }
        
        // Load image generation settings
        geminiApiKey = KeychainHelper.load(key: KeychainHelper.geminiApiKeyKey) ?? ""
        
        // Load Code CLI settings
        let loadedProvider = (KeychainHelper.load(key: KeychainHelper.codeCLIProviderKey) ?? KeychainHelper.defaultCodeCLIProvider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        codeCLIProvider = loadedProvider == "gemini" ? "gemini" : "claude"
        claudeCodeCommand = KeychainHelper.load(key: KeychainHelper.claudeCodeCommandKey) ?? "claude"
        claudeCodeArgs = KeychainHelper.load(key: KeychainHelper.claudeCodeArgsKey) ?? KeychainHelper.defaultClaudeCodeArgs
        claudeCodeTimeout = KeychainHelper.load(key: KeychainHelper.claudeCodeTimeoutKey) ?? KeychainHelper.defaultClaudeCodeTimeout
        geminiCodeCommand = KeychainHelper.load(key: KeychainHelper.geminiCodeCommandKey) ?? KeychainHelper.defaultGeminiCodeCommand
        geminiCodeArgs = KeychainHelper.load(key: KeychainHelper.geminiCodeArgsKey) ?? KeychainHelper.defaultGeminiCodeArgs
        geminiCodeTimeout = KeychainHelper.load(key: KeychainHelper.geminiCodeTimeoutKey) ?? KeychainHelper.defaultGeminiCodeTimeout
        claudeCodeDisableLegacyDocumentGenerationTools =
            (KeychainHelper.load(key: KeychainHelper.claudeCodeDisableLegacyDocumentGenerationToolsKey) ?? "false")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
        
        // Load Vercel deployment settings
        vercelApiToken = KeychainHelper.load(key: KeychainHelper.vercelApiTokenKey) ?? ""
        vercelTeamScope = KeychainHelper.load(key: KeychainHelper.vercelTeamScopeKey) ?? ""
        vercelProjectName = KeychainHelper.load(key: KeychainHelper.vercelProjectNameKey) ?? ""
        vercelCommand = KeychainHelper.load(key: KeychainHelper.vercelCommandKey) ?? KeychainHelper.defaultVercelCommand
        vercelTimeout = KeychainHelper.load(key: KeychainHelper.vercelTimeoutKey) ?? KeychainHelper.defaultVercelTimeout
        
        // Load Instant database settings
        instantApiToken = KeychainHelper.load(key: KeychainHelper.instantApiTokenKey) ?? ""
        instantCLICommand = KeychainHelper.load(key: KeychainHelper.instantCLICommandKey) ?? KeychainHelper.defaultInstantCLICommand
        
        // Load persona settings
        assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? ""
        userName = KeychainHelper.load(key: KeychainHelper.userNameKey) ?? ""
        userContext = KeychainHelper.load(key: KeychainHelper.userContextKey) ?? ""
        structuredUserContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        structuredContextDraft = structuredUserContext
        
        // Load archive settings (show custom value only; default stays as placeholder)
        if let savedChunkSize = KeychainHelper.load(key: KeychainHelper.archiveChunkSizeKey),
           let chunkValue = Int(savedChunkSize),
           chunkValue >= minimumArchiveChunkSize,
           chunkValue != defaultArchiveChunkSize {
            archiveChunkSize = savedChunkSize
        } else {
            archiveChunkSize = ""
        }
    }
    
    private func testConnection() {
        isTesting = true
        botInfo = nil
        testError = nil
        
        Task {
            do {
                let info = try await telegramService.getMe(token: telegramToken)
                await MainActor.run {
                    botInfo = "Connected to @\(info.username ?? info.firstName)"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testError = error.localizedDescription
                    isTesting = false
                }
            }
        }
    }
    
    private func testEmailConnection(testSMTP: Bool) {
        isTestingEmail = true
        emailTestSuccess = nil
        emailTestError = nil
        
        Task {
            // Configure email service temporarily for testing
            await EmailService.shared.configure(
                imapHost: imapHost,
                imapPort: Int(imapPort) ?? 993,
                smtpHost: smtpHost,
                smtpPort: Int(smtpPort) ?? 465,
                username: emailUsername,
                password: emailPassword,
                displayName: emailDisplayName.isEmpty ? emailUsername : emailDisplayName
            )
            
            do {
                let success: Bool
                if testSMTP {
                    success = try await EmailService.shared.testSMTPConnection()
                } else {
                    success = try await EmailService.shared.testIMAPConnection()
                }
                await MainActor.run {
                    emailTestSuccess = testSMTP ? "SMTP connection successful!" : "IMAP connection successful!"
                    isTestingEmail = false
                }
            } catch {
                await MainActor.run {
                    emailTestError = "\(testSMTP ? "SMTP" : "IMAP"): \(error.localizedDescription)"
                    isTestingEmail = false
                }
            }
        }
    }
    
    private func authenticateGmail() {
        isAuthenticatingGmail = true
        gmailAuthStatus = "Opening browser..."
        
        Task {
            // Configure GmailService with credentials
            await GmailService.shared.configure(clientId: gmailClientId, clientSecret: gmailClientSecret)
            
            do {
                let success = try await GmailService.shared.authenticate()
                await MainActor.run {
                    isAuthenticatingGmail = false
                    if success {
                        gmailAuthStatus = "Authenticated ✓"
                    } else {
                        gmailAuthStatus = "Authentication failed"
                    }
                }
            } catch {
                await MainActor.run {
                    isAuthenticatingGmail = false
                    gmailAuthStatus = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func saveSettings() {
        do {
            try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: telegramToken)
            try KeychainHelper.save(key: KeychainHelper.telegramChatIdKey, value: chatId)
            try KeychainHelper.save(key: KeychainHelper.openRouterApiKeyKey, value: openRouterApiKey)
            if !serperApiKey.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: serperApiKey)
            }
            if !jinaApiKey.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.jinaApiKeyKey, value: jinaApiKey)
            }
            if !openRouterModel.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: openRouterModel)
            } else {
                // Clear the saved model if user empties the field to revert to default
                try? KeychainHelper.delete(key: KeychainHelper.openRouterModelKey)
            }
            if !openRouterProviders.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.openRouterProvidersKey, value: openRouterProviders)
            } else {
                try? KeychainHelper.delete(key: KeychainHelper.openRouterProvidersKey)
            }
            if !openRouterReasoningEffort.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.openRouterReasoningEffortKey, value: openRouterReasoningEffort)
            } else {
                try? KeychainHelper.delete(key: KeychainHelper.openRouterReasoningEffortKey)
            }
            
            // Save email settings (always save, even if empty, to allow clearing values)
            try KeychainHelper.save(key: KeychainHelper.imapHostKey, value: imapHost)
            try KeychainHelper.save(key: KeychainHelper.imapPortKey, value: imapPort)
            try KeychainHelper.save(key: KeychainHelper.smtpHostKey, value: smtpHost)
            try KeychainHelper.save(key: KeychainHelper.smtpPortKey, value: smtpPort)
            try KeychainHelper.save(key: KeychainHelper.imapUsernameKey, value: emailUsername)
            try KeychainHelper.save(key: KeychainHelper.imapPasswordKey, value: emailPassword)
            try KeychainHelper.save(key: KeychainHelper.smtpUsernameKey, value: emailUsername)
            try KeychainHelper.save(key: KeychainHelper.smtpPasswordKey, value: emailPassword)
            try KeychainHelper.save(key: KeychainHelper.emailDisplayNameKey, value: emailDisplayName)
            
            // Save Gmail API settings
            try KeychainHelper.save(key: KeychainHelper.emailModeKey, value: emailMode)
            if !gmailClientId.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.gmailClientIdKey, value: gmailClientId)
            }
            if !gmailClientSecret.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.gmailClientSecretKey, value: gmailClientSecret)
            }
            
            // Save image generation settings
            if !geminiApiKey.isEmpty {
                try KeychainHelper.save(key: KeychainHelper.geminiApiKeyKey, value: geminiApiKey)
            }
            
            // Save Code CLI settings
            try saveCodeCLISettings()
            
            // Save Vercel deployment settings
            let normalizedVercelToken = vercelApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedVercelToken.isEmpty {
                try? KeychainHelper.delete(key: KeychainHelper.vercelApiTokenKey)
            } else {
                try KeychainHelper.save(key: KeychainHelper.vercelApiTokenKey, value: normalizedVercelToken)
            }
            
            let normalizedVercelScope = vercelTeamScope.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedVercelScope.isEmpty {
                try? KeychainHelper.delete(key: KeychainHelper.vercelTeamScopeKey)
            } else {
                try KeychainHelper.save(key: KeychainHelper.vercelTeamScopeKey, value: normalizedVercelScope)
            }
            
            let normalizedVercelProject = vercelProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedVercelProject.isEmpty {
                try? KeychainHelper.delete(key: KeychainHelper.vercelProjectNameKey)
            } else {
                try KeychainHelper.save(key: KeychainHelper.vercelProjectNameKey, value: normalizedVercelProject)
            }
            
            let normalizedVercelCommand = vercelCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            try KeychainHelper.save(
                key: KeychainHelper.vercelCommandKey,
                value: normalizedVercelCommand.isEmpty ? KeychainHelper.defaultVercelCommand : normalizedVercelCommand
            )
            
            let vercelTimeoutValue = Int(vercelTimeout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1200
            let clampedVercelTimeout = min(max(vercelTimeoutValue, 60), 3600)
            try KeychainHelper.save(key: KeychainHelper.vercelTimeoutKey, value: "\(clampedVercelTimeout)")
            vercelTimeout = "\(clampedVercelTimeout)"
            
            // Save Instant database settings
            let normalizedInstantToken = instantApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedInstantToken.isEmpty {
                try? KeychainHelper.delete(key: KeychainHelper.instantApiTokenKey)
            } else {
                try KeychainHelper.save(key: KeychainHelper.instantApiTokenKey, value: normalizedInstantToken)
            }
            
            let normalizedInstantCommand = instantCLICommand.trimmingCharacters(in: .whitespacesAndNewlines)
            try KeychainHelper.save(
                key: KeychainHelper.instantCLICommandKey,
                value: normalizedInstantCommand.isEmpty ? KeychainHelper.defaultInstantCLICommand : normalizedInstantCommand
            )
            instantCLICommand = normalizedInstantCommand.isEmpty ? KeychainHelper.defaultInstantCLICommand : normalizedInstantCommand
            
            // Save persona settings
            try KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: assistantName)
            try KeychainHelper.save(key: KeychainHelper.userNameKey, value: userName)
            try KeychainHelper.save(key: KeychainHelper.userContextKey, value: userContext)
            try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: structuredUserContext)
            
            // Save archive settings (empty = default)
            let normalizedChunkSize = archiveChunkSize.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedChunkSize.isEmpty {
                archiveChunkSize = ""
                try KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: "\(defaultArchiveChunkSize)")
            } else if let chunkValue = Int(normalizedChunkSize), chunkValue >= minimumArchiveChunkSize {
                archiveChunkSize = normalizedChunkSize
                try KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: normalizedChunkSize)
            } else {
                // Invalid value, reset to default
                archiveChunkSize = ""
                try KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: "\(defaultArchiveChunkSize)")
            }
            
            showingSaveConfirmation = true
            
            // Hide confirmation after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                showingSaveConfirmation = false
            }
            
            // Configure and auto-start the bot
            Task {
                await conversationManager.configure()
                await conversationManager.startPolling()
            }
        } catch {
            conversationManager.error = "Failed to save settings: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Per-Section Save Functions
    
    @ViewBuilder
    private func sectionSaveButton(_ sectionId: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            if savedSection == sectionId {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Saved")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                .transition(.opacity)
            } else {
                Button("Save") {
                    action()
                    withAnimation {
                        savedSection = sectionId
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            if savedSection == sectionId {
                                savedSection = nil
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
    
    private func savePersonaSection() {
        try? KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: assistantName)
        try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: userName)
    }

    private func beginStructuredContextEdit() {
        structuredContextDraft = structuredUserContext
        isStructuredContextExpanded = true
        isEditingStructuredContext = true
        structuringError = nil
    }

    private func cancelStructuredContextEdit() {
        structuredContextDraft = structuredUserContext
        isEditingStructuredContext = false
    }

    private func saveStructuredContextEdits() {
        let maxContextCharacters = 20000
        var updatedContext = structuredContextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var wasTruncated = false

        if updatedContext.count > maxContextCharacters {
            updatedContext = String(updatedContext.prefix(maxContextCharacters))
            wasTruncated = true
        }

        do {
            try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: updatedContext)
            structuredUserContext = updatedContext
            structuredContextDraft = updatedContext
            isEditingStructuredContext = false
            structuringError = wasTruncated ? "Context exceeded 20,000 characters and was truncated." : nil
        } catch {
            structuringError = "Failed to save edited context: \(error.localizedDescription)"
        }
    }
    
    private func saveTelegramSection() {
        try? KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: telegramToken)
        try? KeychainHelper.save(key: KeychainHelper.telegramChatIdKey, value: chatId)
    }
    
    private func saveOpenRouterSection() {
        try? KeychainHelper.save(key: KeychainHelper.openRouterApiKeyKey, value: openRouterApiKey)
        if !openRouterModel.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: openRouterModel)
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.openRouterModelKey)
        }
        if !openRouterProviders.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.openRouterProvidersKey, value: openRouterProviders)
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.openRouterProvidersKey)
        }
        if !openRouterReasoningEffort.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.openRouterReasoningEffortKey, value: openRouterReasoningEffort)
        } else {
            try? KeychainHelper.delete(key: KeychainHelper.openRouterReasoningEffortKey)
        }
    }
    
    private func saveWebSearchSection() {
        if !serperApiKey.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: serperApiKey)
        }
        if !jinaApiKey.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.jinaApiKeyKey, value: jinaApiKey)
        }
    }
    
    private func saveImageGenSection() {
        if !geminiApiKey.isEmpty {
            try? KeychainHelper.save(key: KeychainHelper.geminiApiKeyKey, value: geminiApiKey)
        }
    }
    
    private func saveClaudeCodeSection() {
        try? saveCodeCLISettings()
    }
    
    private func saveCodeCLISettings() throws {
        let normalizedProvider = codeCLIProvider == "gemini" ? "gemini" : "claude"
        
        let normalizedClaudeCommand = claudeCodeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedClaudeArgs = claudeCodeArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeTimeout = Int(claudeCodeTimeout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 300
        let clampedClaudeTimeout = min(max(claudeTimeout, 30), 3600)
        
        let normalizedGeminiCommand = geminiCodeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGeminiArgs = geminiCodeArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        let geminiTimeout = Int(geminiCodeTimeout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 300
        let clampedGeminiTimeout = min(max(geminiTimeout, 30), 3600)
        
        let saveOp = {
            try KeychainHelper.save(key: KeychainHelper.codeCLIProviderKey, value: normalizedProvider)
            try KeychainHelper.save(
                key: KeychainHelper.claudeCodeCommandKey,
                value: normalizedClaudeCommand.isEmpty ? "claude" : normalizedClaudeCommand
            )
            try KeychainHelper.save(
                key: KeychainHelper.claudeCodeArgsKey,
                value: normalizedClaudeArgs.isEmpty ? KeychainHelper.defaultClaudeCodeArgs : normalizedClaudeArgs
            )
            try KeychainHelper.save(key: KeychainHelper.claudeCodeTimeoutKey, value: "\(clampedClaudeTimeout)")
            
            try KeychainHelper.save(
                key: KeychainHelper.geminiCodeCommandKey,
                value: normalizedGeminiCommand.isEmpty ? KeychainHelper.defaultGeminiCodeCommand : normalizedGeminiCommand
            )
            try KeychainHelper.save(
                key: KeychainHelper.geminiCodeArgsKey,
                value: normalizedGeminiArgs.isEmpty ? KeychainHelper.defaultGeminiCodeArgs : normalizedGeminiArgs
            )
            try KeychainHelper.save(key: KeychainHelper.geminiCodeTimeoutKey, value: "\(clampedGeminiTimeout)")
            
            try KeychainHelper.save(
                key: KeychainHelper.claudeCodeDisableLegacyDocumentGenerationToolsKey,
                value: claudeCodeDisableLegacyDocumentGenerationTools ? "true" : "false"
            )
        }
        
        try saveOp()
        
        codeCLIProvider = normalizedProvider
        claudeCodeCommand = normalizedClaudeCommand.isEmpty ? "claude" : normalizedClaudeCommand
        claudeCodeArgs = normalizedClaudeArgs.isEmpty ? KeychainHelper.defaultClaudeCodeArgs : normalizedClaudeArgs
        claudeCodeTimeout = "\(clampedClaudeTimeout)"
        
        geminiCodeCommand = normalizedGeminiCommand.isEmpty ? KeychainHelper.defaultGeminiCodeCommand : normalizedGeminiCommand
        geminiCodeArgs = normalizedGeminiArgs.isEmpty ? KeychainHelper.defaultGeminiCodeArgs : normalizedGeminiArgs
        geminiCodeTimeout = "\(clampedGeminiTimeout)"
    }
    
    private func saveVercelSection() {
        let normalizedToken = vercelApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedScope = vercelTeamScope.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProject = vercelProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommand = vercelCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if normalizedToken.isEmpty {
            try? KeychainHelper.delete(key: KeychainHelper.vercelApiTokenKey)
        } else {
            try? KeychainHelper.save(key: KeychainHelper.vercelApiTokenKey, value: normalizedToken)
        }
        
        if normalizedScope.isEmpty {
            try? KeychainHelper.delete(key: KeychainHelper.vercelTeamScopeKey)
        } else {
            try? KeychainHelper.save(key: KeychainHelper.vercelTeamScopeKey, value: normalizedScope)
        }
        
        if normalizedProject.isEmpty {
            try? KeychainHelper.delete(key: KeychainHelper.vercelProjectNameKey)
        } else {
            try? KeychainHelper.save(key: KeychainHelper.vercelProjectNameKey, value: normalizedProject)
        }
        
        let timeout = Int(vercelTimeout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1200
        let clamped = min(max(timeout, 60), 3600)
        
        try? KeychainHelper.save(
            key: KeychainHelper.vercelCommandKey,
            value: normalizedCommand.isEmpty ? KeychainHelper.defaultVercelCommand : normalizedCommand
        )
        try? KeychainHelper.save(key: KeychainHelper.vercelTimeoutKey, value: "\(clamped)")
        
        vercelApiToken = normalizedToken
        vercelTeamScope = normalizedScope
        vercelProjectName = normalizedProject
        vercelCommand = normalizedCommand.isEmpty ? KeychainHelper.defaultVercelCommand : normalizedCommand
        vercelTimeout = "\(clamped)"
    }
    
    private func saveInstantDatabaseSection() {
        let normalizedToken = instantApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommand = instantCLICommand.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if normalizedToken.isEmpty {
            try? KeychainHelper.delete(key: KeychainHelper.instantApiTokenKey)
        } else {
            try? KeychainHelper.save(key: KeychainHelper.instantApiTokenKey, value: normalizedToken)
        }
        
        try? KeychainHelper.save(
            key: KeychainHelper.instantCLICommandKey,
            value: normalizedCommand.isEmpty ? KeychainHelper.defaultInstantCLICommand : normalizedCommand
        )
        
        instantApiToken = normalizedToken
        instantCLICommand = normalizedCommand.isEmpty ? KeychainHelper.defaultInstantCLICommand : normalizedCommand
    }
    
    private func saveEmailSection() {
        try? KeychainHelper.save(key: KeychainHelper.emailModeKey, value: emailMode)
        if emailMode == "imap" {
            try? KeychainHelper.save(key: KeychainHelper.imapHostKey, value: imapHost)
            try? KeychainHelper.save(key: KeychainHelper.imapPortKey, value: imapPort)
            try? KeychainHelper.save(key: KeychainHelper.smtpHostKey, value: smtpHost)
            try? KeychainHelper.save(key: KeychainHelper.smtpPortKey, value: smtpPort)
            try? KeychainHelper.save(key: KeychainHelper.imapUsernameKey, value: emailUsername)
            try? KeychainHelper.save(key: KeychainHelper.imapPasswordKey, value: emailPassword)
            try? KeychainHelper.save(key: KeychainHelper.smtpUsernameKey, value: emailUsername)
            try? KeychainHelper.save(key: KeychainHelper.smtpPasswordKey, value: emailPassword)
            try? KeychainHelper.save(key: KeychainHelper.emailDisplayNameKey, value: emailDisplayName)
        } else {
            if !gmailClientId.isEmpty {
                try? KeychainHelper.save(key: KeychainHelper.gmailClientIdKey, value: gmailClientId)
            }
            if !gmailClientSecret.isEmpty {
                try? KeychainHelper.save(key: KeychainHelper.gmailClientSecretKey, value: gmailClientSecret)
            }
        }
    }
    
    private func saveArchiveChunkSize() {
        // Validate and save archive chunk size (empty = default)
        let normalizedChunkSize = archiveChunkSize.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let valueToSave: String
        if normalizedChunkSize.isEmpty {
            archiveChunkSize = ""
            valueToSave = "\(defaultArchiveChunkSize)"
        } else if let chunkValue = Int(normalizedChunkSize), chunkValue >= minimumArchiveChunkSize {
            archiveChunkSize = normalizedChunkSize
            valueToSave = normalizedChunkSize
        } else {
            // Invalid value, reset to default
            archiveChunkSize = ""
            valueToSave = "\(defaultArchiveChunkSize)"
        }
        
        do {
            try KeychainHelper.save(key: KeychainHelper.archiveChunkSizeKey, value: valueToSave)
            withAnimation {
                showingChunkSizeSaved = true
            }
            // Hide checkmark after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showingChunkSizeSaved = false
                }
            }
        } catch {
            conversationManager.error = "Failed to save chunk size: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Mind Export/Import
    
    private func exportMind() {
        isExportingMind = true
        mindExportSuccess = nil
        mindExportError = nil
        
        Task {
            do {
                // Create save panel
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.data]
                savePanel.nameFieldStringValue = "TelegramConcierge_Mind.\(MindExportService.fileExtension)"
                savePanel.title = "Export Mind"
                savePanel.message = "Choose where to save your mind backup"
                
                let response = await savePanel.beginSheetModal(for: NSApp.mainWindow ?? NSWindow())
                
                guard response == .OK, let url = savePanel.url else {
                    await MainActor.run {
                        isExportingMind = false
                    }
                    return
                }
                
                try await MindExportService.shared.exportMind(to: url)
                
                await MainActor.run {
                    mindExportSuccess = "Mind exported successfully!"
                    isExportingMind = false
                    
                    // Clear success message after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        mindExportSuccess = nil
                    }
                }
            } catch {
                await MainActor.run {
                    mindExportError = "Export failed: \(error.localizedDescription)"
                    isExportingMind = false
                }
            }
        }
    }
    
    private func importMind(from url: URL) {
        isImportingMind = true
        mindExportSuccess = nil
        mindExportError = nil
        pendingImportURL = nil
        
        Task {
            do {
                try await MindExportService.shared.importMind(from: url)
                
                // Reload conversation and archives to pick up restored data
                await conversationManager.reloadAfterMindRestore()
                
                // Clean up temp file
                try? FileManager.default.removeItem(at: url)
                
                await MainActor.run {
                    mindExportSuccess = "Mind restored successfully!"
                    isImportingMind = false
                    
                    // Refresh persona settings after import
                    assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? ""
                    userName = KeychainHelper.load(key: KeychainHelper.userNameKey) ?? ""
                    userContext = KeychainHelper.load(key: KeychainHelper.userContextKey) ?? ""
                    structuredUserContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
                    structuredContextDraft = structuredUserContext
                    isEditingStructuredContext = false
                }
            } catch {
                // Clean up temp file
                try? FileManager.default.removeItem(at: url)
                
                await MainActor.run {
                    mindExportError = "Import failed: \(error.localizedDescription)"
                    isImportingMind = false
                }
            }
        }
    }
    
    // MARK: - Calendar Export/Import
    
    private func exportCalendar() {
        isExportingCalendar = true
        calendarExportSuccess = nil
        calendarExportError = nil
        
        Task {
            // Get calendar data
            guard let calendarData = await CalendarService.shared.getEventsData() else {
                await MainActor.run {
                    calendarExportError = "Failed to export calendar data"
                    isExportingCalendar = false
                }
                return
            }
            
            // Create save panel
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.json]
            savePanel.nameFieldStringValue = "TelegramConcierge_Calendar.json"
            savePanel.title = "Export Calendar"
            savePanel.message = "Choose where to save your calendar backup"
            
            let response = await savePanel.beginSheetModal(for: NSApp.mainWindow ?? NSWindow())
            
            guard response == .OK, let url = savePanel.url else {
                await MainActor.run {
                    isExportingCalendar = false
                }
                return
            }
            
            do {
                try calendarData.write(to: url)
                
                await MainActor.run {
                    calendarExportSuccess = "Calendar exported successfully!"
                    isExportingCalendar = false
                    
                    // Clear success message after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        calendarExportSuccess = nil
                    }
                }
            } catch {
                await MainActor.run {
                    calendarExportError = "Export failed: \(error.localizedDescription)"
                    isExportingCalendar = false
                }
            }
        }
    }
    
    private func importCalendar(from url: URL) {
        isImportingCalendar = true
        calendarExportSuccess = nil
        calendarExportError = nil
        
        Task {
            do {
                let data = try Data(contentsOf: url)
                try await CalendarService.shared.importEvents(from: data)
                
                await MainActor.run {
                    calendarExportSuccess = "Calendar imported successfully!"
                    isImportingCalendar = false
                    
                    // Refresh count
                    Task {
                        calendarEventCount = await CalendarService.shared.totalEventCount()
                    }
                    
                    // Clear success message after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        calendarExportSuccess = nil
                    }
                }
            } catch {
                await MainActor.run {
                    calendarExportError = "Import failed: \(error.localizedDescription)"
                    isImportingCalendar = false
                }
            }
        }
    }
    
    private func structureUserContext() {
        isStructuring = true
        structuringError = nil
        
        Task {
            do {
                let structured = try await structureWithAI(
                    assistantName: assistantName,
                    userName: userName,
                    rawContext: userContext,
                    apiKey: openRouterApiKey
                )
                await MainActor.run {
                    structuredUserContext = structured
                    structuredContextDraft = structured
                    userContext = ""
                    isEditingStructuredContext = false
                    try? KeychainHelper.save(key: KeychainHelper.userContextKey, value: "")
                    try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: structured)
                    isStructuring = false
                }
            } catch {
                await MainActor.run {
                    structuringError = error.localizedDescription
                    isStructuring = false
                }
            }
        }
    }
    
    private func structureWithAI(assistantName: String, userName: String, rawContext: String, apiKey: String) async throws -> String {
        // Load existing structured context
        let existingContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        
        let prompt: String
        let maxChars = 20000
        let existingCharCount = existingContext.count
        let currentTokens = existingCharCount / 4
        let remainingTokens = (maxChars - existingCharCount) / 4
        
        if existingContext.isEmpty {
            // No existing context - structure from user input
            prompt = """
            You are helping configure an AI assistant. Based on the user's input, create a structured context.
            
            ⚠️ TOKEN LIMIT: ~5000 tokens (~20,000 characters). Currently using 0 tokens. You have ~5000 tokens available.
            
            Assistant Name: \(assistantName.isEmpty ? "not specified" : assistantName)
            User Name: \(userName.isEmpty ? "not specified" : userName)
            Raw User Input: \(rawContext)
            
            Write ONLY the structured context, no explanations. It should:
            1. Establish the assistant's identity and name (if provided)
            2. Establish who the user is and their name (if provided)
            3. Include relevant preferences and facts from the user input
            4. Be written in second person ("You are...")
            5. Organize by categories if there's enough information (Personal, Work, Preferences, etc.)
            6. Stay within the token limit - be concise but comprehensive
            """
        } else {
            // Existing context exists - Gemini decides how to handle the update
            prompt = """
            You are helping update an AI assistant's persistent memory about the user.
            
            ⚠️ TOKEN LIMIT: ~5000 tokens (~20,000 characters). Currently using ~\(currentTokens) tokens. You have ~\(remainingTokens) tokens remaining.
            
            EXISTING CONTEXT (current memory):
            ---
            \(existingContext)
            ---
            
            NEW USER INPUT:
            ---
            \(rawContext.isEmpty ? "(empty - user cleared the field)" : rawContext)
            ---
            
            Your task: Decide how to update the context intelligently.
            
            IMPORTANT RULES:
            - If the new input is EMPTY or just a few words, DO NOT delete the existing context. Keep it as-is or make minimal changes.
            - If the new input contains corrections (e.g., "birthday is actually April"), UPDATE the relevant parts.
            - If the new input adds new information, APPEND it to the appropriate section.
            - If the new input is a complete rewrite with substantial content, you may restructure entirely.
            - NEVER lose important information from the existing context unless explicitly told to remove it.
            - Stay within the 5000 token limit. If space is tight, remove less important details.
            
            Assistant Name: \(assistantName.isEmpty ? "not specified" : assistantName)
            User Name: \(userName.isEmpty ? "not specified" : userName)
            
            Output ONLY the final structured context (no explanations). Keep it organized and concise.
            """
        }
        
        let body: [String: Any] = [
            "model": "google/gemini-3-flash-preview",
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "StructureAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "API request failed"])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "StructureAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    SettingsView()
        .environmentObject(ConversationManager())
}
