import SwiftUI
import Foundation

struct ClaudeProjectsBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var projects: [ClaudeLocalProject] = []
    @State private var selectedProjectID: String?
    @State private var currentRelativePath: String = "."
    @State private var entries: [ClaudeLocalEntry] = []
    @State private var errorMessage: String?
    @State private var projectPendingDeletion: ClaudeLocalProject?
    @State private var showBulkDeleteConfirmation = false
    
    private var selectedProject: ClaudeLocalProject? {
        projects.first { $0.id == selectedProjectID }
    }
    
    private var flaggedProjects: [ClaudeLocalProject] {
        projects.filter(\.isFlaggedForDeletion)
    }
    
    private var canGoUp: Bool {
        currentRelativePath != "."
    }
    
    private var projectsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge/projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedProjectID) {
                ForEach(projects) { project in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .font(.body)
                            Text(project.id)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let description = project.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            if let lastEditedAt = project.lastEditedAt {
                                Text("Last edited: \(Self.dateFormatter.string(from: lastEditedAt))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if project.isFlaggedForDeletion {
                                Text("Flagged for deletion")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                if let reason = project.deletionFlagReason, !reason.isEmpty {
                                    Text(reason)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        
                        Spacer(minLength: 8)
                        
                        if project.isFlaggedForDeletion {
                            Button(role: .destructive) {
                                projectPendingDeletion = project
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete this flagged project")
                        }
                    }
                    .tag(Optional(project.id))
                }
            }
            .navigationTitle("Claude Projects")
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                if let project = selectedProject {
                    HStack {
                        Text(project.name)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(project.createdAt, formatter: Self.dateFormatter)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Text("Path: \(currentRelativePath)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    
                    if let description = project.description, !description.isEmpty {
                        Text(description)
                            .font(.callout)
                    }
                    
                    if let lastEditedAt = project.lastEditedAt {
                        Text("Last edited: \(lastEditedAt, formatter: Self.dateFormatter)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if project.isFlaggedForDeletion {
                        HStack(spacing: 8) {
                            Image(systemName: "trash.fill")
                                .foregroundColor(.red)
                            Text("Flagged for deletion")
                                .font(.callout)
                                .foregroundColor(.red)
                            Spacer()
                            Button("Delete This Project", role: .destructive) {
                                projectPendingDeletion = project
                            }
                        }
                        
                        if let reason = project.deletionFlagReason, !reason.isEmpty {
                            Text("Reason: \(reason)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    List(entries) { entry in
                        if entry.isDirectory {
                            Button {
                                openDirectory(entry.relativePath)
                            } label: {
                                projectEntryRow(entry)
                            }
                            .buttonStyle(.plain)
                        } else {
                            projectEntryRow(entry)
                        }
                    }
                    .listStyle(.inset)
                } else {
                    ContentUnavailableView(
                        "No Project Selected",
                        systemImage: "folder",
                        description: Text("Choose a project from the left to browse files.")
                    )
                }
            }
            .padding()
            .navigationTitle("Project Browser")
            .toolbar {
                ToolbarItemGroup {
                    Button("Delete Flagged (\(flaggedProjects.count))", role: .destructive) {
                        showBulkDeleteConfirmation = true
                    }
                    .disabled(flaggedProjects.isEmpty)
                    
                    Button("Refresh") {
                        loadProjects()
                    }
                    Button("Up") {
                        navigateUp()
                    }
                    .disabled(!canGoUp)
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            loadProjects()
        }
        .onChange(of: selectedProjectID) { newProjectID in
            guard let newProjectID else {
                entries = []
                currentRelativePath = "."
                return
            }
            
            if projects.contains(where: { $0.id == newProjectID }) {
                currentRelativePath = "."
                loadEntries()
            }
        }
        .alert(item: $projectPendingDeletion) { project in
            Alert(
                title: Text("Delete '\(project.name)'?"),
                message: Text("This permanently deletes the flagged project from disk. This cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    deleteFlaggedProjects(withIDs: [project.id])
                },
                secondaryButton: .cancel()
            )
        }
        .alert("Delete all flagged projects?", isPresented: $showBulkDeleteConfirmation) {
            Button("Delete \(flaggedProjects.count) Project\(flaggedProjects.count == 1 ? "" : "s")", role: .destructive) {
                deleteFlaggedProjects(withIDs: flaggedProjects.map(\.id))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all projects currently flagged by Gemini. This cannot be undone.")
        }
    }
    
    @ViewBuilder
    private func projectEntryRow(_ entry: ClaudeLocalEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundColor(entry.isDirectory ? .accentColor : .secondary)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if let sizeBytes = entry.sizeBytes, !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
    
    private func loadProjects() {
        errorMessage = nil
        
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: projectsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            var loaded: [ClaudeLocalProject] = []
            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                
                let metadata = loadMetadata(from: url)
                let projectID = metadata?.id ?? url.lastPathComponent
                let projectName = metadata?.name ?? url.lastPathComponent
                
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let createdAt = metadata?.createdAt ?? (attrs?[.creationDate] as? Date) ?? .distantPast
                
                loaded.append(
                    ClaudeLocalProject(
                        id: projectID,
                        name: projectName,
                        description: metadata?.projectDescription,
                        lastEditedAt: metadata?.lastEditedAt,
                        createdAt: createdAt,
                        isFlaggedForDeletion: metadata?.flaggedForDeletion ?? false,
                        deletionFlaggedAt: metadata?.deletionFlaggedAt,
                        deletionFlagReason: metadata?.deletionFlagReason,
                        url: url
                    )
                )
            }
            
            projects = loaded.sorted { lhs, rhs in
                let lhsDate = lhs.lastEditedAt ?? lhs.createdAt
                let rhsDate = rhs.lastEditedAt ?? rhs.createdAt
                return lhsDate > rhsDate
            }
            
            if let selectedProjectID, projects.contains(where: { $0.id == selectedProjectID }) {
                loadEntries()
            } else if let first = projects.first {
                self.selectedProjectID = first.id
                currentRelativePath = "."
                loadEntries()
            } else {
                selectedProjectID = nil
                currentRelativePath = "."
                entries = []
            }
        } catch {
            errorMessage = "Failed to load projects: \(error.localizedDescription)"
            projects = []
            entries = []
        }
    }
    
    private func deleteFlaggedProjects(withIDs projectIDs: [String]) {
        let targets = projects.filter { project in
            projectIDs.contains(project.id) && project.isFlaggedForDeletion
        }
        
        guard !targets.isEmpty else {
            errorMessage = "No flagged projects were selected for deletion."
            return
        }
        
        var deletedCount = 0
        var failedDeletes: [String] = []
        let fileManager = FileManager.default
        
        for project in targets {
            do {
                try fileManager.removeItem(at: project.url)
                deletedCount += 1
            } catch {
                failedDeletes.append("\(project.name): \(error.localizedDescription)")
            }
        }
        
        if failedDeletes.isEmpty {
            errorMessage = nil
        } else {
            errorMessage = "Deleted \(deletedCount) project(s), failed \(failedDeletes.count): \(failedDeletes.joined(separator: " | "))"
        }
        
        loadProjects()
    }
    
    private func loadEntries() {
        errorMessage = nil
        guard let project = selectedProject else {
            entries = []
            return
        }
        
        guard let targetURL = resolvePath(for: project, relativePath: currentRelativePath) else {
            errorMessage = "Invalid path."
            entries = []
            return
        }
        
        do {
            let childURLs = try FileManager.default.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            let loadedEntries: [ClaudeLocalEntry] = childURLs.compactMap { childURL in
                let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDirectory = values?.isDirectory ?? false
                let relativePath = relativePath(from: project.url, to: childURL)
                
                return ClaudeLocalEntry(
                    id: relativePath,
                    name: childURL.lastPathComponent,
                    relativePath: relativePath,
                    isDirectory: isDirectory,
                    sizeBytes: isDirectory ? nil : values?.fileSize
                )
            }
            
            entries = loadedEntries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } catch {
            errorMessage = "Failed to load folder: \(error.localizedDescription)"
            entries = []
        }
    }
    
    private func openDirectory(_ relativePath: String) {
        guard let project = selectedProject else { return }
        guard let targetURL = resolvePath(for: project, relativePath: relativePath) else { return }
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        
        currentRelativePath = relativePath
        loadEntries()
    }
    
    private func navigateUp() {
        guard canGoUp else { return }
        guard let project = selectedProject else { return }
        
        let currentURL = resolvePath(for: project, relativePath: currentRelativePath) ?? project.url
        let parent = currentURL.deletingLastPathComponent()
        
        let rootPath = project.url.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        guard parentPath.hasPrefix(rootPath) else { return }
        
        currentRelativePath = relativePath(from: project.url, to: parent)
        loadEntries()
    }
    
    private func resolvePath(for project: ClaudeLocalProject, relativePath: String) -> URL? {
        let normalized = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = normalized.isEmpty ? "." : normalized
        guard !path.hasPrefix("/") else { return nil }
        
        let target = project.url.appendingPathComponent(path).standardizedFileURL
        let root = project.url.standardizedFileURL.path
        guard target.path.hasPrefix(root) else { return nil }
        
        return target
    }
    
    private func relativePath(from root: URL, to child: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        
        if childPath == rootPath {
            return "."
        }
        
        if childPath.hasPrefix(rootPath + "/") {
            return String(childPath.dropFirst(rootPath.count + 1))
        }
        
        return child.lastPathComponent
    }
    
    private func loadMetadata(from projectURL: URL) -> ClaudeProjectMetadataFile? {
        let metadataURL = projectURL.appendingPathComponent(".project.json")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        
        let defaultDecoder = JSONDecoder()
        if let metadata = try? defaultDecoder.decode(ClaudeProjectMetadataFile.self, from: data) {
            return metadata
        }
        
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        return try? isoDecoder.decode(ClaudeProjectMetadataFile.self, from: data)
    }
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct ClaudeLocalProject: Identifiable {
    let id: String
    let name: String
    let description: String?
    let lastEditedAt: Date?
    let createdAt: Date
    let isFlaggedForDeletion: Bool
    let deletionFlaggedAt: Date?
    let deletionFlagReason: String?
    let url: URL
}

private struct ClaudeLocalEntry: Identifiable {
    let id: String
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let sizeBytes: Int?
}

private struct ClaudeProjectMetadataFile: Decodable {
    let id: String
    let name: String
    let createdAt: Date
    let projectDescription: String?
    let lastEditedAt: Date?
    let flaggedForDeletion: Bool?
    let deletionFlaggedAt: Date?
    let deletionFlagReason: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "createdAt"
        case projectDescription = "projectDescription"
        case lastEditedAt = "lastEditedAt"
        case flaggedForDeletion = "flaggedForDeletion"
        case deletionFlaggedAt = "deletionFlaggedAt"
        case deletionFlagReason = "deletionFlagReason"
    }
}

#Preview {
    ClaudeProjectsBrowserView()
}
