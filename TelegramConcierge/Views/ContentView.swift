import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @Environment(\.openSettings) private var openSettings
    @State private var scrollProxy: ScrollViewProxy?
    @State private var fileDescriptions: [String: String] = [:]
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(conversationManager.messages.enumerated()), id: \.element.id) { index, message in
                            VStack(spacing: 8) {
                                // Date separator (when day changes)
                                if shouldShowDateHeader(at: index) {
                                    dateSeparator(for: message.timestamp)
                                }
                                
                                MessageBubbleView(
                                    message: message,
                                    imageURLs: conversationManager.imageURLs(for: message),
                                    referencedImageURLs: conversationManager.referencedImageURLs(for: message),
                                    fileDescriptions: fileDescriptions
                                )
                            }
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onAppear {
                    scrollProxy = proxy
                }
                .onChange(of: conversationManager.messages.count) { _, _ in
                    scrollToBottom()
                    loadFileDescriptions()
                }
            }
            
            Divider()
            
            // Status bar
            statusBar
        }
        .frame(minWidth: 520, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loadFileDescriptionsAsync()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProjectsZipAutoExtractor.invalidRootFilesDetectedNotification)) { notification in
            guard let filenames = notification.userInfo?["filenames"] as? [String], !filenames.isEmpty else { return }
            let preview = filenames.prefix(5).joined(separator: ", ")
            let extraCount = max(0, filenames.count - 5)
            let filesText = extraCount > 0 ? "\(preview), +\(extraCount) more" : preview
            presentAlert(
                title: "Unsupported Files in Projects Folder",
                message: "Only folders or .zip files are supported directly in this location. Move these file(s) into a folder or zip archive: \(filesText)"
            )
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
    
    // MARK: - Date Separator
    
    private func shouldShowDateHeader(at index: Int) -> Bool {
        let messages = conversationManager.messages
        guard index < messages.count else { return false }
        
        if index == 0 { return true }
        
        let calendar = Calendar.current
        let currentDate = messages[index].timestamp
        let previousDate = messages[index - 1].timestamp
        return !calendar.isDate(currentDate, inSameDayAs: previousDate)
    }
    
    private func dateSeparator(for date: Date) -> some View {
        HStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
            
            Text(formatDateHeader(date))
                .font(.caption)
                .foregroundColor(.secondary)
                .fontWeight(.medium)
                .fixedSize()
            
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }
    
    private func formatDateHeader(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter.string(from: date)
    }
    
    // MARK: - File Descriptions
    
    private func loadFileDescriptions() {
        Task {
            await loadFileDescriptionsAsync()
        }
    }
    
    private func loadFileDescriptionsAsync() async {
        let descriptions = await FileDescriptionService.shared.getAll()
        await MainActor.run {
            fileDescriptions = descriptions
        }
    }
    
    // MARK: - Header
    
    @State private var settingsHover = false
    @State private var projectsHover = false
    
    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // App identity
                VStack(alignment: .leading, spacing: 1) {
                    Text("Telegram Concierge")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("AI Chatbot")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 6) {
                    // Settings button
                    headerIconButton(
                        systemImage: "gearshape.fill",
                        helpText: "Open Settings",
                        isHovering: $settingsHover,
                        action: { openSettings() }
                    )
                    
                    // Projects button (conditional)
                    if isClaudeDocumentGenerationEnabled {
                        Button(action: openClaudeProjectsFolderInFinder) {
                            Label("Projects", systemImage: "folder.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(projectsHover ? .primary : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(projectsHover
                                              ? Color(nsColor: .controlBackgroundColor)
                                              : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(projectsHover
                                                ? Color.secondary.opacity(0.25)
                                                : Color.secondary.opacity(0.1), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                projectsHover = hovering
                            }
                        }
                        .help("Open Projects Folder")
                    }
                }
                
                // Polling toggle
                HStack(spacing: 6) {
                    Circle()
                        .fill(conversationManager.isPolling ? Color.green : Color.gray.opacity(0.4))
                        .frame(width: 7, height: 7)
                    
                    Toggle(isOn: Binding(
                        get: { conversationManager.isPolling },
                        set: { newValue in
                            Task {
                                if newValue {
                                    await conversationManager.startPolling()
                                } else {
                                    conversationManager.stopPolling()
                                }
                            }
                        }
                    )) {
                        Text(conversationManager.isPolling ? "Active" : "Inactive")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(conversationManager.isPolling ? .primary : .secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.green)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
    
    // MARK: - Status Bar
    
    private var statusBar: some View {
        HStack {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(conversationManager.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            // Clear conversation button
            Button(action: {
                conversationManager.clearConversation()
            }) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Clear conversation")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var statusColor: Color {
        if conversationManager.error != nil {
            return .red
        } else if conversationManager.isPolling {
            return .green
        } else {
            return .gray
        }
    }
    
    private func scrollToBottom() {
        if let lastMessage = conversationManager.messages.last {
            withAnimation(.easeOut(duration: 0.3)) {
                scrollProxy?.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
    
    private var isClaudeDocumentGenerationEnabled: Bool {
        (KeychainHelper.load(key: KeychainHelper.claudeCodeDisableLegacyDocumentGenerationToolsKey) ?? "false")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
    }
    
    private func headerIconButton(
        systemImage: String,
        helpText: String,
        isHovering: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovering.wrappedValue ? .primary : .secondary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(isHovering.wrappedValue
                              ? Color(nsColor: .controlBackgroundColor)
                              : Color.clear)
                )
                .overlay(
                    Circle()
                        .stroke(isHovering.wrappedValue
                                ? Color.secondary.opacity(0.2)
                                : Color.clear, lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering.wrappedValue = hovering
            }
        }
        .help(helpText)
    }

    private var claudeProjectsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge/projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func openClaudeProjectsFolderInFinder() {
        let didOpen = NSWorkspace.shared.open(claudeProjectsDirectory)
        guard !didOpen else { return }
        presentAlert(
            title: "Unable to Open Folder",
            message: "Could not open the Claude projects folder in Finder."
        )
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    ContentView()
        .environmentObject(ConversationManager())
}
