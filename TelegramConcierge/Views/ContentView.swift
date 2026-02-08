import SwiftUI

struct ContentView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @Environment(\.openSettings) private var openSettings
    @State private var scrollProxy: ScrollViewProxy?
    @State private var fileDescriptions: [String: String] = [:]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
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
        .frame(minWidth: 400, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loadFileDescriptionsAsync()
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
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Telegram Concierge")
                    .font(.headline)
                Text("AI Chatbot")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Open Settings")
            .padding(.trailing, 8)
            
            // Polling toggle
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
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .tint(.green)
        }
        .padding()
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
}

#Preview {
    ContentView()
        .environmentObject(ConversationManager())
}
