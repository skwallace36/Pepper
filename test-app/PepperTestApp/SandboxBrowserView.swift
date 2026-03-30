import SwiftUI

struct SandboxBrowserView: View {
    @State private var directories: [SandboxDirectory] = []
    @State private var totalSize: Int = 0
    @State private var selectedFile: SandboxFile?
    @State private var fileContent: String = ""

    var body: some View {
        List {
            Section {
                HStack {
                    Label("Total Storage", systemImage: "internaldrive")
                    Spacer()
                    Text(formatSize(totalSize))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sandbox_total_size")
                }
            }

            ForEach(directories) { dir in
                Section {
                    HStack {
                        Label(dir.name, systemImage: dir.icon)
                            .font(.headline)
                        Spacer()
                        Text("\(dir.files.count) files")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("sandbox_\(dir.key)_count")
                    }

                    ForEach(dir.files) { file in
                        Button {
                            selectedFile = file
                            loadContent(of: file)
                        } label: {
                            HStack {
                                Image(systemName: iconForFile(file.name))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 8) {
                                        Text(formatSize(file.size))
                                        Text(file.modifiedString)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if file.isSeeded {
                                    Text("Seeded")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.1))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .accessibilityIdentifier("sandbox_file_\(file.name)")
                    }

                    if dir.files.isEmpty {
                        Text("No files")
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                }
            }

            if let selected = selectedFile, !fileContent.isEmpty {
                Section("Content: \(selected.name)") {
                    Text(fileContent)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("sandbox_file_content")
                }
            }
        }
        .navigationTitle("Sandbox Browser")
        .onAppear { refresh() }
        .refreshable { refresh() }
    }

    private func refresh() {
        let fm = FileManager.default
        var dirs: [SandboxDirectory] = []
        var total = 0

        let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        let libURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
        let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let seededFiles: Set<String> = [
            "notes.json", "settings.plist", "cached-image.txt", "temp-data.txt",
        ]

        let entries: [(String, String, String, URL?)] = [
            ("Documents", "documents", "folder", docsURL),
            ("Library", "library", "building.columns", libURL),
            ("Caches", "caches", "archivebox", cachesURL),
            ("tmp", "tmp", "clock.arrow.circlepath", tmpURL),
        ]

        for (name, key, icon, url) in entries {
            guard let url else { continue }
            let files = listFiles(at: url, fm: fm, seededNames: seededFiles)
            let dirSize = files.reduce(0) { $0 + $1.size }
            total += dirSize
            dirs.append(SandboxDirectory(name: name, key: key, icon: icon, files: files))
        }

        directories = dirs
        totalSize = total
    }

    private func listFiles(at url: URL, fm: FileManager, seededNames: Set<String>) -> [SandboxFile] {
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else { return [] }

        return contents.compactMap { fileURL in
            let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
            ])
            let isFile = values?.isRegularFile ?? false
            guard isFile else { return nil }
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate
            let name = fileURL.lastPathComponent
            return SandboxFile(
                name: name,
                url: fileURL,
                size: size,
                modified: modified,
                isSeeded: seededNames.contains(name)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isSeeded != rhs.isSeeded { return lhs.isSeeded }
            return lhs.name < rhs.name
        }
    }

    private func loadContent(of file: SandboxFile) {
        fileContent = (try? String(contentsOf: file.url, encoding: .utf8)) ?? "<binary data>"
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func iconForFile(_ name: String) -> String {
        if name.hasSuffix(".json") { return "doc.text" }
        if name.hasSuffix(".plist") { return "list.bullet.rectangle" }
        if name.hasSuffix(".db") || name.hasSuffix(".sqlite") { return "cylinder" }
        if name.hasSuffix(".txt") { return "doc.plaintext" }
        return "doc"
    }
}

// MARK: - Models

struct SandboxDirectory: Identifiable {
    let id = UUID()
    let name: String
    let key: String
    let icon: String
    let files: [SandboxFile]
}

struct SandboxFile: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let size: Int
    let modified: Date?
    let isSeeded: Bool

    var modifiedString: String {
        guard let modified else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: modified)
    }
}
