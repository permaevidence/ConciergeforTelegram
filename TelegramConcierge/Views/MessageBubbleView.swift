import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    var imageURLs: [URL] = []
    var referencedImageURLs: [URL] = []
    var fileDescriptions: [String: String] = [:]
    
    private var isUser: Bool {
        message.role == .user
    }
    
    var body: some View {
        HStack {
            if isUser {
                Spacer(minLength: 60)
            }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                // Referenced attachments (from replied-to messages)
                if !message.referencedImageFileNames.isEmpty || !message.referencedDocumentFileNames.isEmpty {
                    referencedAttachmentsView
                }
                
                // Referenced images (thumbnails)
                if !referencedImageURLs.isEmpty {
                    referencedImagesView
                }
                
                // Primary images (all of them, not just the first)
                if !imageURLs.isEmpty {
                    primaryImagesView
                }
                
                // Primary document attachments
                if !message.documentFileNames.isEmpty {
                    primaryDocumentsView
                }
                
                // Text content
                if !message.content.isEmpty {
                    Text(message.content)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleColor)
                        .foregroundColor(textColor)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                
                // Downloaded files (email attachments on assistant messages)
                if !message.downloadedDocumentFileNames.isEmpty {
                    downloadedFilesView
                }
                
                // Accessed projects (permanent log)
                if !message.accessedProjectIds.isEmpty {
                    accessedProjectsView
                }
                
                Text(formattedTime)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if !isUser {
                Spacer(minLength: 60)
            }
        }
    }
    
    // MARK: - Primary Images
    
    private var primaryImagesView: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 250, maxHeight: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        case .failure:
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                                .frame(width: 100, height: 100)
                        case .empty:
                            ProgressView()
                                .frame(width: 100, height: 100)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    
                    // Show filename + AI description
                    if index < message.imageFileNames.count {
                        let filename = message.imageFileNames[index]
                        fileChip(
                            icon: "photo",
                            color: .blue,
                            filename: filename,
                            description: fileDescriptions[filename]
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - Referenced Images
    
    private var referencedImagesView: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            ForEach(Array(referencedImageURLs.enumerated()), id: \.offset) { index, url in
                VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 200, maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                                )
                        case .failure:
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundColor(.secondary)
                                .frame(width: 80, height: 80)
                        case .empty:
                            ProgressView()
                                .frame(width: 80, height: 80)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    
                    if index < message.referencedImageFileNames.count {
                        let filename = message.referencedImageFileNames[index]
                        fileChip(
                            icon: "arrowshape.turn.up.left",
                            color: .purple,
                            label: "Referenced",
                            filename: filename,
                            description: fileDescriptions[filename]
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - Referenced Attachments (text labels for docs)
    
    private var referencedAttachmentsView: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            ForEach(message.referencedDocumentFileNames, id: \.self) { filename in
                fileChip(
                    icon: "arrowshape.turn.up.left",
                    color: .purple,
                    label: "Referenced",
                    filename: filename,
                    description: fileDescriptions[filename]
                )
            }
        }
    }
    
    // MARK: - Primary Documents
    
    private var primaryDocumentsView: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            ForEach(message.documentFileNames, id: \.self) { filename in
                fileChip(
                    icon: documentIcon(for: filename),
                    color: .orange,
                    filename: filename,
                    description: fileDescriptions[filename]
                )
            }
        }
    }
    
    // MARK: - Downloaded Files
    
    private var downloadedFilesView: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            ForEach(message.downloadedDocumentFileNames, id: \.self) { filename in
                fileChip(
                    icon: "arrow.down.circle",
                    color: .teal,
                    label: "Downloaded",
                    filename: filename,
                    description: fileDescriptions[filename]
                )
            }
        }
    }
    
    // MARK: - Accessed Projects
    
    private var accessedProjectsView: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            ForEach(message.accessedProjectIds, id: \.self) { projectId in
                fileChip(
                    icon: "folder",
                    color: .indigo,
                    label: "Accessed Project",
                    filename: projectId,
                    description: nil
                )
            }
        }
    }
    
    // MARK: - File Chip Component
    
    private func fileChip(
        icon: String,
        color: Color,
        label: String? = nil,
        filename: String,
        description: String?
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(color)
            
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let label = label {
                        Text(label)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(color)
                    }
                    Text(shortFilename(filename))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                if let desc = description {
                    Text(desc)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .italic()
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }
    
    // MARK: - Helpers
    
    private var bubbleColor: Color {
        if isUser {
            return Color.accentColor
        } else {
            return Color(nsColor: .controlBackgroundColor)
        }
    }
    
    private var textColor: Color {
        if isUser {
            return .white
        } else {
            return Color(nsColor: .labelColor)
        }
    }
    
    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: message.timestamp)
    }
    
    /// Extract just the filename from the path
    private func shortFilename(_ filename: String) -> String {
        URL(fileURLWithPath: filename).lastPathComponent
    }
    
    /// Choose icon based on file extension
    private func documentIcon(for filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "txt", "md": return "doc.plaintext"
        case "mp4", "mov", "avi", "mkv", "webm": return "film"
        case "mp3", "m4a", "wav", "flac", "aac", "opus": return "waveform"
        case "ogg", "oga": return "mic"
        case "json", "csv": return "tablecells"
        default: return "doc"
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        MessageBubbleView(message: Message(role: .user, content: "Hello, how are you?"))
        MessageBubbleView(message: Message(role: .assistant, content: "I'm doing great! How can I help you today?"))
        MessageBubbleView(
            message: Message(
                role: .user,
                content: "Check this document",
                documentFileNames: ["report.pdf"],
                documentFileSizes: [1024]
            ),
            fileDescriptions: ["report.pdf": "A quarterly financial report for Q4 2025"]
        )
    }
    .padding()
    .frame(width: 400)
}
