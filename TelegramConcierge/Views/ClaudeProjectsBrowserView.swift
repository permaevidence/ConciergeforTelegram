import SwiftUI
import Foundation
import AppKit

struct ClaudeProjectsBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var projects: [ClaudeLocalProject] = []
    @State private var selectedProjectID: String?
    @State private var currentRelativePath: String = "."
    @State private var entries: [ClaudeLocalEntry] = []
    @State private var errorMessage: String?
    @State private var exportStatusMessage: String?
    @State private var isExportingProjects = false
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

                        Button {
                            downloadProject(project)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isExportingProjects)
                        .help("Download this project as a ZIP")
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

                    if isExportingProjects {
                        ProgressView("Preparing download...")
                            .font(.caption)
                    }

                    if let exportStatusMessage {
                        Text(exportStatusMessage)
                            .font(.caption)
                            .foregroundColor(.green)
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
                    Button("Download Selected") {
                        guard let selectedProject else { return }
                        downloadProject(selectedProject)
                    }
                    .disabled(selectedProject == nil || isExportingProjects)
                    Button("Download All (\(projects.count))") {
                        downloadAllProjects()
                    }
                    .disabled(projects.isEmpty || isExportingProjects)
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
        .frame(minWidth: 940, minHeight: 560)
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

    private static let allProjectsFileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    private func downloadProject(_ project: ClaudeLocalProject) {
        isExportingProjects = true
        exportStatusMessage = nil
        errorMessage = nil

        Task {
            let fileName = "\(sanitizedFileName(project.name)).zip"
            guard let destinationURL = await promptForDownloadURL(
                defaultFileName: fileName,
                title: "Download Project",
                message: "Choose where to save the project archive."
            ) else {
                await MainActor.run { isExportingProjects = false }
                return
            }

            do {
                try await createZipArchive(
                    from: project.url.deletingLastPathComponent(),
                    including: [project.url.lastPathComponent],
                    destination: destinationURL
                )

                await MainActor.run {
                    isExportingProjects = false
                    exportStatusMessage = "Downloaded '\(project.name)' successfully."
                    clearExportStatusAfterDelay()
                }
            } catch {
                await MainActor.run {
                    isExportingProjects = false
                    errorMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func downloadAllProjects() {
        guard !projects.isEmpty else {
            errorMessage = "No projects available to download."
            return
        }

        isExportingProjects = true
        exportStatusMessage = nil
        errorMessage = nil

        Task {
            let timestamp = Self.allProjectsFileDateFormatter.string(from: Date())
            let fileName = "ClaudeProjects_\(timestamp).zip"

            guard let destinationURL = await promptForDownloadURL(
                defaultFileName: fileName,
                title: "Download All Projects",
                message: "Choose where to save all project folders."
            ) else {
                await MainActor.run { isExportingProjects = false }
                return
            }

            let folderNames = projects.map { $0.url.lastPathComponent }

            do {
                try await createZipArchive(
                    from: projectsDirectory,
                    including: folderNames,
                    destination: destinationURL
                )

                await MainActor.run {
                    isExportingProjects = false
                    exportStatusMessage = "Downloaded \(folderNames.count) project folder(s) successfully."
                    clearExportStatusAfterDelay()
                }
            } catch {
                await MainActor.run {
                    isExportingProjects = false
                    errorMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    private func promptForDownloadURL(defaultFileName: String, title: String, message: String) async -> URL? {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.data]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = defaultFileName
        savePanel.title = title
        savePanel.message = message

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await savePanel.beginSheetModal(for: window)
        } else {
            response = await withCheckedContinuation { continuation in
                savePanel.begin { modalResponse in
                    continuation.resume(returning: modalResponse)
                }
            }
        }

        guard response == .OK else { return nil }
        return savePanel.url
    }

    private func createZipArchive(from sourceDirectory: URL, including items: [String], destination: URL) async throws {
        guard !items.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fileManager = FileManager.default
                let tempZipURL = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")

                defer {
                    try? fileManager.removeItem(at: tempZipURL)
                }

                do {
                    if fileManager.fileExists(atPath: tempZipURL.path) {
                        try fileManager.removeItem(at: tempZipURL)
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                    process.currentDirectoryURL = sourceDirectory
                    process.arguments = ["-r", "-q", tempZipURL.path] + items

                    let errorPipe = Pipe()
                    process.standardError = errorPipe

                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown zip error."
                        continuation.resume(throwing: ClaudeProjectsDownloadError.zipFailed(errorMessage))
                        return
                    }

                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.copyItem(at: tempZipURL, to: destination)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let components = name.components(separatedBy: invalidCharacters)
        let sanitized = components.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "ClaudeProject" : sanitized
    }

    @MainActor
    private func clearExportStatusAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            exportStatusMessage = nil
        }
    }
}

private enum ClaudeProjectsDownloadError: LocalizedError {
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .zipFailed(let message):
            return "Failed to create ZIP archive: \(message)"
        }
    }
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
