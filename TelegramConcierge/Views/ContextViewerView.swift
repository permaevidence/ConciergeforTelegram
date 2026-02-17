import SwiftUI

/// A debug view that displays all context being sent to Gemini in the system prompt.
/// Organized into collapsible sections for each context type.
struct ContextViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversationManager: ConversationManager
    
    @State private var isLoading = true
    @State private var currentMessages: [Message] = []
    @State private var chunkSummaries: [ConversationChunk] = []
    @State private var userContext: String = ""
    @State private var structuredUserContext: String = ""
    @State private var assistantName: String = ""
    @State private var userName: String = ""
    @State private var calendarContext: String = ""
    @State private var emailContext: String = ""
    @State private var selectedChunk: ConversationChunk?
    @State private var selectedChunkContent: String = ""
    @State private var isChunkContentLoading = false
    @State private var chunkContentError: String?
    
    // Expansion states
    @State private var isConversationExpanded = true
    @State private var isChunksExpanded = true
    @State private var isUserContextExpanded = true
    @State private var isCalendarExpanded = true
    @State private var isEmailExpanded = true
    @State private var isSystemPromptExpanded = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "brain")
                        .font(.title)
                        .foregroundColor(.purple)
                    
                    VStack(alignment: .leading) {
                        Text("Context Viewer")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("All context currently visible to Gemini")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button {
                        Task {
                            await refreshContext()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color.purple.opacity(0.1))
                .cornerRadius(10)
                
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading context...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                } else {
                    // MARK: - User Context Section
                    CollapsibleSection(
                        title: "User Context / Persona",
                        systemImage: "person.text.rectangle",
                        color: .blue,
                        isExpanded: $isUserContextExpanded
                    ) {
                        userContextContent
                    }
                    
                    // MARK: - Current Conversation Section
                    CollapsibleSection(
                        title: "Current Conversation",
                        systemImage: "bubble.left.and.bubble.right",
                        color: .green,
                        badge: "\(currentMessages.count) messages",
                        isExpanded: $isConversationExpanded
                    ) {
                        conversationContent
                    }
                    
                    // MARK: - Archived Chunks Section
                    CollapsibleSection(
                        title: "Archived Chunk Summaries",
                        systemImage: "archivebox",
                        color: .orange,
                        badge: "\(chunkSummaries.count) chunks",
                        isExpanded: $isChunksExpanded
                    ) {
                        chunksContent
                    }
                    
                    // MARK: - Calendar Context Section
                    CollapsibleSection(
                        title: "Calendar Context",
                        systemImage: "calendar",
                        color: .red,
                        isExpanded: $isCalendarExpanded
                    ) {
                        calendarContent
                    }
                    
                    // MARK: - Email Context Section
                    CollapsibleSection(
                        title: "Email Context",
                        systemImage: "envelope",
                        color: .indigo,
                        isExpanded: $isEmailExpanded
                    ) {
                        emailContent
                    }
                    
                    // MARK: - System Prompt Preview Section
                    CollapsibleSection(
                        title: "System Prompt Preview",
                        systemImage: "doc.text",
                        color: .gray,
                        isExpanded: $isSystemPromptExpanded
                    ) {
                        systemPromptContent
                    }
                }
            }
            .padding()
        }
        .frame(width: 600, height: 700)
        .onAppear {
            Task {
                await refreshContext()
            }
        }
        .sheet(item: $selectedChunk) { chunk in
            chunkDetailSheet(for: chunk)
        }
    }
    
    // MARK: - Section Contents
    
    @ViewBuilder
    private var userContextContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !assistantName.isEmpty {
                LabeledContent("Assistant Name", value: assistantName)
            }
            if !userName.isEmpty {
                LabeledContent("User Name", value: userName)
            }
            
            if !structuredUserContext.isEmpty {
                Text("Structured Context (used in prompts):")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ScrollView {
                    Text(structuredUserContext)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(5)
            } else if !userContext.isEmpty {
                Text("Raw Context (not yet structured):")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(userContext)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.yellow.opacity(0.1))
                    .cornerRadius(5)
            } else {
                Text("No user context configured. Set it in Settings → Persona.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
    
    @ViewBuilder
    private var conversationContent: some View {
        if currentMessages.isEmpty {
            Text("No messages in current conversation.")
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(currentMessages.enumerated()), id: \.element.id) { index, message in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(message.role == .user ? "👤 User" : "🤖 Assistant")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                
                                Text(message.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                
                                if message.imageFileName != nil {
                                    Image(systemName: "photo")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                                if message.documentFileName != nil {
                                    Image(systemName: "doc")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                            
                            Text(message.content.prefix(200) + (message.content.count > 200 ? "..." : ""))
                                .font(.caption)
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    if index < currentMessages.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(8)
            .background(Color.green.opacity(0.05))
            .cornerRadius(5)
        }
    }
    
    @ViewBuilder
    private var chunksContent: some View {
        if chunkSummaries.isEmpty {
            Text("No archived conversation chunks yet.")
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(chunkSummaries.enumerated()), id: \.element.id) { index, chunk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Chunk \(index + 1)")
                                .font(.caption)
                                .fontWeight(.semibold)
                            
                            Text(chunk.sizeLabel)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(chunk.type == .consolidated ? Color.purple.opacity(0.2) : Color.gray.opacity(0.2))
                                .cornerRadius(4)
                            
                            Spacer()
                            
                            Text(formatDateRange(start: chunk.startDate, end: chunk.endDate))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Text(chunk.summary)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task {
                                    await loadChunkContent(for: chunk)
                                }
                            }
                            .help("Click to view full chunk content")
                        
                        Text("ID: \(chunk.id.uuidString.prefix(8))... • \(chunk.messageCount) messages")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.05))
                    .cornerRadius(5)
                }
            }
        }
    }
    
    @ViewBuilder
    private var calendarContent: some View {
        if calendarContext.isEmpty {
            Text("No calendar context available.")
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()
        } else {
            ScrollView {
                Text(calendarContext)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(8)
            .background(Color.red.opacity(0.05))
            .cornerRadius(5)
        }
    }
    
    @ViewBuilder
    private var emailContent: some View {
        if emailContext.isEmpty {
            Text("No email context available. Configure email in Settings.")
                .font(.caption)
                .foregroundColor(.secondary)
                .italic()
        } else {
            ScrollView {
                Text(emailContext)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(8)
            .background(Color.indigo.opacity(0.05))
            .cornerRadius(5)
        }
    }
    
    @ViewBuilder
    private var systemPromptContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This shows how the system prompt is structured:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            ScrollView {
                Text(buildSystemPromptPreview())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            .padding(8)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(5)
        }
    }
    
    // MARK: - Data Loading
    
    private func refreshContext() async {
        isLoading = true
        
        // Load persona settings from Keychain
        assistantName = KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? ""
        userName = KeychainHelper.load(key: KeychainHelper.userNameKey) ?? ""
        userContext = KeychainHelper.load(key: KeychainHelper.userContextKey) ?? ""
        structuredUserContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        
        // Get conversation context
        let context = await conversationManager.getContextForStructuring()
        currentMessages = context.recentMessages
        chunkSummaries = context.chunkSummaries
        
        // Get calendar context
        calendarContext = await CalendarService.shared.getCalendarContextForSystemPrompt()
        
        // Get email context (check which service is active)
        let emailMode = KeychainHelper.load(key: KeychainHelper.emailModeKey) ?? "imap"
        if emailMode == "gmail" {
            emailContext = await GmailService.shared.getEmailContextForSystemPrompt()
        } else {
            emailContext = await EmailService.shared.getEmailContextForSystemPrompt()
        }
        
        isLoading = false
    }
    
    // MARK: - Helpers
    
    private func formatDateRange(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }
    
    private func buildSystemPromptPreview() -> String {
        var preview = """
        === SYSTEM PROMPT STRUCTURE ===
        
        """
        
        // Persona intro
        if !structuredUserContext.isEmpty {
            preview += """
            [PERSONA / USER CONTEXT]
            \(structuredUserContext.prefix(500))...
            
            """
        } else {
            var intro = ""
            if !assistantName.isEmpty {
                intro += "Your name is \(assistantName). "
            }
            if !userName.isEmpty {
                intro += "You are assisting \(userName). "
            }
            if intro.isEmpty {
                intro = "You are a helpful AI assistant."
            }
            preview += """
            [PERSONA]
            \(intro)
            
            """
        }
        
        // Communication context
        preview += """
        [COMMUNICATION]
        The user communicates with you via Telegram. They may send text messages, voice messages (which are automatically transcribed before you receive them), images, and documents.
        
        [CURRENT DATE/TIME]
        **Current date and time**: (injected at request time)
        ⚠️ This timestamp is essential—use it as your reference for ALL time-sensitive reasoning.
        
        """
        
        // Calendar
        if !calendarContext.isEmpty {
            preview += """
            [CALENDAR CONTEXT]
            \(calendarContext.prefix(300))...
            
            """
        }
        
        // Email
        if !emailContext.isEmpty {
            preview += """
            [EMAIL CONTEXT]
            \(emailContext.prefix(300))...
            
            """
        }
        
        // Chunks
        if !chunkSummaries.isEmpty {
            preview += """
            [ARCHIVED CONVERSATION HISTORY]
            You have access to \(chunkSummaries.count) chunk(s) of older conversation history.
            Use `search_conversation_history` to retrieve details.
            
            """
        }
        
        // Tool instructions
        preview += """
        [TOOL INSTRUCTIONS]
        You have access to tools that can help you answer questions.
        Use them when appropriate, especially for:
        - Current events, news, or real-time data
        - Prices, stock quotes, weather, or availability
        - Calendar management
        - Email operations
        - Web search
        - Reminders
        - Learning about the user (edit_user_context)
        
        """
        
        return preview
    }
    
    @ViewBuilder
    private func chunkDetailSheet(for chunk: ConversationChunk) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Summary")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(chunk.summary)
                        .font(.body)
                    
                    Text("Period: \(formatDateRange(start: chunk.startDate, end: chunk.endDate)) • \(chunk.messageCount) messages • \(chunk.sizeLabel)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                if isChunkContentLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading full chunk content...")
                            .foregroundColor(.secondary)
                    }
                } else if let chunkContentError {
                    Text("Failed to load chunk: \(chunkContentError)")
                        .font(.caption)
                        .foregroundColor(.red)
                } else if selectedChunkContent.isEmpty {
                    Text("No content available for this chunk.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ScrollView {
                        Text(selectedChunkContent)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.05))
                    .cornerRadius(6)
                }
            }
            .padding()
            .navigationTitle("Chunk \(chunk.id.uuidString.prefix(8))")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        selectedChunk = nil
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 560)
    }
    
    private func loadChunkContent(for chunk: ConversationChunk) async {
        let chunkId = chunk.id
        selectedChunk = chunk
        selectedChunkContent = ""
        chunkContentError = nil
        isChunkContentLoading = true
        
        do {
            let content = try await conversationManager.getArchivedChunkContent(chunkId: chunkId)
            guard selectedChunk?.id == chunkId else { return }
            selectedChunkContent = content
        } catch {
            guard selectedChunk?.id == chunkId else { return }
            chunkContentError = error.localizedDescription
        }
        
        if selectedChunk?.id == chunkId {
            isChunkContentLoading = false
        }
    }
}

// MARK: - Collapsible Section Component

struct CollapsibleSection<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    var badge: String? = nil
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: systemImage)
                        .foregroundColor(color)
                    
                    Text(title)
                        .fontWeight(.semibold)
                    
                    if let badge = badge {
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.2))
                            .cornerRadius(4)
                    }
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

#Preview {
    ContextViewerView()
}
