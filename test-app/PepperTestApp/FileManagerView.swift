import SwiftUI

struct FileManagerView: View {
    @State private var files: [FileItem] = []
    @State private var selectedFile: FileItem?
    @State private var fileContent: String = ""
    @State private var newFileName: String = ""
    @State private var showingCreateSheet = false

    var body: some View {
        List {
            Section("Documents/") {
                ForEach(files) { file in
                    Button {
                        selectedFile = file
                        loadContent(of: file)
                    } label: {
                        HStack {
                            Image(systemName: iconForFile(file.name))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(file.name)
                                    .foregroundStyle(.primary)
                                Text(file.sizeString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("file_\(file.name)")
                }
                .onDelete(perform: deleteFiles)
            }

            if let selected = selectedFile, !fileContent.isEmpty {
                Section("Content: \(selected.name)") {
                    Text(fileContent)
                        .font(.system(.caption, design: .monospaced))
                        .accessibilityIdentifier("file_content")
                }
            }
        }
        .navigationTitle("File Manager")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Create File", systemImage: "plus") {
                    showingCreateSheet = true
                }
                .accessibilityIdentifier("create_file_button")
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateFileSheet(onCreate: { name, content in
                createFile(name: name, content: content)
                showingCreateSheet = false
            })
        }
        .onAppear { refreshFiles() }
    }

    private func refreshFiles() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let items = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        files = items.compactMap { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return FileItem(name: url.lastPathComponent, url: url, size: size)
        }.sorted { $0.name < $1.name }
    }

    private func loadContent(of file: FileItem) {
        fileContent = (try? String(contentsOf: file.url, encoding: .utf8)) ?? "<binary>"
    }

    private func createFile(name: String, content: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        print("[PepperTest] Created file: \(name)")
        refreshFiles()
    }

    private func deleteFiles(at offsets: IndexSet) {
        for index in offsets {
            let file = files[index]
            try? FileManager.default.removeItem(at: file.url)
            print("[PepperTest] Deleted file: \(file.name)")
        }
        refreshFiles()
    }

    private func iconForFile(_ name: String) -> String {
        if name.hasSuffix(".json") { return "doc.text" }
        if name.hasSuffix(".plist") { return "list.bullet.rectangle" }
        return "doc"
    }
}

// MARK: - FileItem

struct FileItem: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let size: Int

    var sizeString: String {
        if size < 1024 { return "\(size) B" }
        return String(format: "%.1f KB", Double(size) / 1024)
    }
}

// MARK: - CreateFileSheet

struct CreateFileSheet: View {
    let onCreate: (String, String) -> Void
    @State private var name = "new-file.txt"
    @State private var content = "Hello from Pepper"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("File Name") {
                    TextField("filename.txt", text: $name)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("new_file_name")
                }
                Section("Content") {
                    TextField("File content", text: $content, axis: .vertical)
                        .lineLimit(4...8)
                        .accessibilityIdentifier("new_file_content")
                }
            }
            .navigationTitle("Create File")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard !name.isEmpty else { return }
                        onCreate(name, content)
                    }
                    .accessibilityIdentifier("confirm_create_button")
                }
            }
        }
    }
}
