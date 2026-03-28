import Foundation

/// Handles {"cmd": "sandbox"} commands for app sandbox file system access.
///
/// Actions:
///   - "paths":    Show container directory paths (Documents, Library, Caches, tmp, bundle).
///   - "list":     List files/directories at a path. Params: path, recursive (optional).
///   - "read":     Read file contents (text, JSON, plist). Params: path.
///   - "write":    Write/overwrite a file. Params: path, content, base64 (optional).
///   - "delete":   Delete a file or directory. Params: path.
///   - "info":     File attributes (size, dates, type). Params: path.
///   - "size":     Directory size summary (cache bloat detection). Params: path (optional).
struct SandboxHandler: PepperHandler {
    let commandName = "sandbox"

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "paths"

        switch action {
        case "paths":
            return handlePaths(command)
        case "list":
            return handleList(command)
        case "read":
            return handleRead(command)
        case "write":
            return handleWrite(command)
        case "delete":
            return handleDelete(command)
        case "info":
            return handleInfo(command)
        case "size":
            return handleSize(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown sandbox action '\(action)'. Use paths/list/read/write/delete/info/size."
            )
        }
    }

    // MARK: - Paths

    private func handlePaths(_ command: PepperCommand) -> PepperResponse {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        var paths: [String: AnyCodable] = [
            "home": AnyCodable(home),
            "documents": AnyCodable(home + "/Documents"),
            "library": AnyCodable(home + "/Library"),
            "caches": AnyCodable(home + "/Library/Caches"),
            "tmp": AnyCodable(NSTemporaryDirectory()),
        ]

        if let bundle = Bundle.main.bundlePath as String? {
            paths["bundle"] = AnyCodable(bundle)
        }

        // Add existence flags
        var info: [[String: AnyCodable]] = []
        let dirs: [(String, String)] = [
            ("documents", home + "/Documents"),
            ("library", home + "/Library"),
            ("caches", home + "/Library/Caches"),
            ("tmp", NSTemporaryDirectory()),
        ]
        for (name, dirPath) in dirs {
            var count = 0
            do {
                count = try fm.contentsOfDirectory(atPath: dirPath).count
            } catch {
                pepperLog.debug("contentsOfDirectory failed at \(dirPath): \(error)", category: .commands)
            }
            info.append([
                "name": AnyCodable(name),
                "path": AnyCodable(dirPath),
                "item_count": AnyCodable(count),
            ])
        }

        return .ok(
            id: command.id,
            data: [
                "paths": AnyCodable(paths),
                "directories": AnyCodable(info),
            ])
    }

    // MARK: - List

    private func handleList(_ command: PepperCommand) -> PepperResponse {
        guard let path = resolvePath(command) else {
            return .error(id: command.id, message: "Missing 'path' param.")
        }

        let fm = FileManager.default
        let recursive = command.params?["recursive"]?.boolValue ?? false
        let limit = command.params?["limit"]?.intValue ?? 200

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return .error(id: command.id, message: "Not a directory: \(path)")
        }

        let contents: [String]
        do {
            contents =
                try recursive
                ? fm.subpathsOfDirectory(atPath: path)
                : fm.contentsOfDirectory(atPath: path)
        } catch {
            pepperLog.warning("Failed to list directory at \(path): \(error)", category: .commands)
            contents = []
        }

        var entries: [[String: AnyCodable]] = []
        for name in contents.sorted().prefix(limit) {
            let fullPath = (path as NSString).appendingPathComponent(name)
            var itemIsDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &itemIsDir)

            var entry: [String: AnyCodable] = [
                "name": AnyCodable(name),
                "type": AnyCodable(itemIsDir.boolValue ? "directory" : "file"),
            ]

            do {
                let attrs = try fm.attributesOfItem(atPath: fullPath)
                if let size = attrs[.size] as? UInt64 {
                    entry["size"] = AnyCodable(Int(size))
                }
                if let modified = attrs[.modificationDate] as? Date {
                    entry["modified"] = AnyCodable(ISO8601DateFormatter().string(from: modified))
                }
            } catch {
                pepperLog.debug("attributesOfItem failed at \(fullPath): \(error)", category: .commands)
            }

            entries.append(entry)
        }

        return .ok(
            id: command.id,
            data: [
                "path": AnyCodable(path),
                "count": AnyCodable(entries.count),
                "total": AnyCodable(contents.count),
                "entries": AnyCodable(entries),
            ])
    }

    // MARK: - Read

    private func handleRead(_ command: PepperCommand) -> PepperResponse {
        guard let path = resolvePath(command) else {
            return .error(id: command.id, message: "Missing 'path' param.")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return .error(id: command.id, message: "File not found: \(path)")
        }

        guard let data = fm.contents(atPath: path) else {
            return .error(id: command.id, message: "Cannot read file: \(path)")
        }

        // Plist → pretty JSON
        if path.hasSuffix(".plist") {
            do {
                let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                do {
                    let json = try JSONSerialization.data(
                        withJSONObject: plist, options: [.prettyPrinted, .sortedKeys])
                    if let str = String(data: json, encoding: .utf8) {
                        return .ok(
                            id: command.id,
                            data: [
                                "path": AnyCodable(path), "format": AnyCodable("plist"),
                                "content": AnyCodable(str), "size": AnyCodable(data.count),
                            ])
                    }
                } catch {
                    pepperLog.debug(
                        "Failed to serialize plist to JSON at \(path): \(error) — falling through to text",
                        category: .commands)
                }
            } catch {
                pepperLog.debug(
                    "Failed to parse plist at \(path): \(error) — falling through to text", category: .commands)
            }
        }

        // JSON → pretty-print
        if path.hasSuffix(".json") {
            do {
                let obj = try JSONSerialization.jsonObject(with: data)
                do {
                    let pretty = try JSONSerialization.data(
                        withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                    if let str = String(data: pretty, encoding: .utf8) {
                        return .ok(
                            id: command.id,
                            data: [
                                "path": AnyCodable(path), "format": AnyCodable("json"),
                                "content": AnyCodable(str), "size": AnyCodable(data.count),
                            ])
                    }
                } catch {
                    pepperLog.debug(
                        "Failed to re-serialize JSON at \(path): \(error) — falling through to text",
                        category: .commands)
                }
            } catch {
                pepperLog.debug(
                    "Failed to parse JSON at \(path): \(error) — falling through to text", category: .commands)
            }
        }

        // Text
        if let text = String(data: data, encoding: .utf8) {
            let maxLen = command.params?["max_length"]?.intValue ?? 50_000
            let truncated = text.count > maxLen
            return .ok(
                id: command.id,
                data: [
                    "path": AnyCodable(path), "format": AnyCodable("text"),
                    "content": AnyCodable(truncated ? String(text.prefix(maxLen)) : text),
                    "size": AnyCodable(text.count), "truncated": AnyCodable(truncated),
                ])
        }

        // Binary → base64
        let maxBytes = command.params?["max_length"]?.intValue ?? 10_000
        let truncated = data.count > maxBytes
        let slice = truncated ? data.prefix(maxBytes) : data
        return .ok(
            id: command.id,
            data: [
                "path": AnyCodable(path), "format": AnyCodable("base64"),
                "content": AnyCodable(slice.base64EncodedString()),
                "size": AnyCodable(data.count), "truncated": AnyCodable(truncated),
            ])
    }

    // MARK: - Write

    private func handleWrite(_ command: PepperCommand) -> PepperResponse {
        guard let path = resolvePath(command) else {
            return .error(id: command.id, message: "Missing 'path' param.")
        }

        // Prevent writes to the app bundle
        if let bundlePath = Bundle.main.bundlePath as String?,
            path.hasPrefix(bundlePath)
        {
            return .error(id: command.id, message: "Cannot write to app bundle (read-only).")
        }

        let isBase64 = command.params?["base64"]?.boolValue ?? false
        let fm = FileManager.default

        let data: Data
        if isBase64 {
            guard let b64 = command.params?["content"]?.stringValue,
                let decoded = Data(base64Encoded: b64)
            else {
                return .error(id: command.id, message: "Invalid base64 content.")
            }
            data = decoded
        } else {
            guard let content = command.params?["content"]?.stringValue else {
                return .error(id: command.id, message: "Missing 'content' param.")
            }
            guard let encoded = content.data(using: .utf8) else {
                return .error(id: command.id, message: "Cannot encode content as UTF-8.")
            }
            data = encoded
        }

        // Create parent directories if needed
        let parent = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            do {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            } catch {
                return .error(id: command.id, message: "Cannot create directory: \(error.localizedDescription)")
            }
        }

        let existed = fm.fileExists(atPath: path)
        if fm.createFile(atPath: path, contents: data) {
            return .ok(
                id: command.id,
                data: [
                    "path": AnyCodable(path),
                    "size": AnyCodable(data.count),
                    "created": AnyCodable(!existed),
                    "ok": AnyCodable(true),
                ])
        }

        return .error(id: command.id, message: "Failed to write file: \(path)")
    }

    // MARK: - Delete

    private func handleDelete(_ command: PepperCommand) -> PepperResponse {
        guard let path = resolvePath(command) else {
            return .error(id: command.id, message: "Missing 'path' param.")
        }

        // Prevent deleting the app bundle
        if let bundlePath = Bundle.main.bundlePath as String?,
            path.hasPrefix(bundlePath)
        {
            return .error(id: command.id, message: "Cannot delete from app bundle (read-only).")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return .error(id: command.id, message: "Not found: \(path)")
        }

        do {
            try fm.removeItem(atPath: path)
            return .ok(
                id: command.id,
                data: [
                    "path": AnyCodable(path),
                    "removed": AnyCodable(true),
                ])
        } catch {
            return .error(id: command.id, message: "Delete failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Info

    private func handleInfo(_ command: PepperCommand) -> PepperResponse {
        guard let path = resolvePath(command) else {
            return .error(id: command.id, message: "Missing 'path' param.")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return .error(id: command.id, message: "Not found: \(path)")
        }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: path)
        } catch {
            return .error(id: command.id, message: "Cannot read attributes: \(path): \(error.localizedDescription)")
        }

        let iso = ISO8601DateFormatter()
        var data: [String: AnyCodable] = [
            "path": AnyCodable(path),
            "type": AnyCodable(fileTypeLabel(attrs[.type] as? FileAttributeType)),
        ]

        if let size = attrs[.size] as? UInt64 {
            data["size"] = AnyCodable(Int(size))
            data["size_formatted"] = AnyCodable(formatBytes(size))
        }
        if let modified = attrs[.modificationDate] as? Date {
            data["modified"] = AnyCodable(iso.string(from: modified))
        }
        if let created = attrs[.creationDate] as? Date {
            data["created"] = AnyCodable(iso.string(from: created))
        }
        if let posix = attrs[.posixPermissions] as? Int {
            data["permissions"] = AnyCodable(String(posix, radix: 8))
        }

        return .ok(id: command.id, data: data)
    }

    // MARK: - Size

    private func handleSize(_ command: PepperCommand) -> PepperResponse {
        let home = NSHomeDirectory()
        let path = resolvePath(command) ?? home

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return .error(id: command.id, message: "Not a directory: \(path)")
        }

        let dirs: [(String, String)]
        if path == home {
            dirs = [
                ("Documents", home + "/Documents"),
                ("Library", home + "/Library"),
                ("Library/Caches", home + "/Library/Caches"),
                ("tmp", NSTemporaryDirectory()),
            ]
        } else {
            // List immediate subdirectories
            var rawContents: [String] = []
            do {
                rawContents = try fm.contentsOfDirectory(atPath: path)
            } catch {
                pepperLog.debug("contentsOfDirectory failed at \(path): \(error)", category: .commands)
            }
            dirs = rawContents.sorted().compactMap { name in
                let full = (path as NSString).appendingPathComponent(name)
                var sub: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &sub), sub.boolValue {
                    return (name, full)
                }
                return nil
            }
        }

        var entries: [[String: AnyCodable]] = []
        var totalSize: UInt64 = 0

        for (name, dirPath) in dirs {
            let size = directorySize(dirPath)
            totalSize += size
            var itemCount = 0
            do {
                itemCount = try fm.contentsOfDirectory(atPath: dirPath).count
            } catch {
                pepperLog.debug("contentsOfDirectory failed at \(dirPath): \(error)", category: .commands)
            }
            entries.append([
                "name": AnyCodable(name),
                "path": AnyCodable(dirPath),
                "size": AnyCodable(Int(size)),
                "size_formatted": AnyCodable(formatBytes(size)),
                "item_count": AnyCodable(itemCount),
            ])
        }

        return .ok(
            id: command.id,
            data: [
                "path": AnyCodable(path),
                "total_size": AnyCodable(Int(totalSize)),
                "total_formatted": AnyCodable(formatBytes(totalSize)),
                "directories": AnyCodable(entries),
            ])
    }

    // MARK: - Helpers

    private func resolvePath(_ command: PepperCommand) -> String? {
        guard let raw = command.params?["path"]?.stringValue else { return nil }

        let home = NSHomeDirectory()

        // Handle shorthand prefixes
        if raw.hasPrefix("~/") {
            return home + String(raw.dropFirst(1))
        }
        if raw.hasPrefix("documents/") || raw == "documents" {
            return home + "/Documents" + (raw == "documents" ? "" : String(raw.dropFirst(9)))
        }
        if raw.hasPrefix("caches/") || raw == "caches" {
            return home + "/Library/Caches" + (raw == "caches" ? "" : String(raw.dropFirst(6)))
        }
        if raw.hasPrefix("library/") || raw == "library" {
            return home + "/Library" + (raw == "library" ? "" : String(raw.dropFirst(7)))
        }
        if raw.hasPrefix("tmp/") || raw == "tmp" {
            return NSTemporaryDirectory() + (raw == "tmp" ? "" : String(raw.dropFirst(3)))
        }
        if raw.hasPrefix("bundle/") || raw == "bundle" {
            let bundlePath = Bundle.main.bundlePath
            return bundlePath + (raw == "bundle" ? "" : String(raw.dropFirst(6)))
        }

        // Absolute path — use as-is
        if raw.hasPrefix("/") {
            return raw
        }

        // Relative to home
        return home + "/" + raw
    }

    private func directorySize(_ path: String) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }

        var total: UInt64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            do {
                let attrs = try fm.attributesOfItem(atPath: fullPath)
                if let size = attrs[.size] as? UInt64 {
                    total += size
                }
            } catch {
                pepperLog.debug("attributesOfItem failed at \(fullPath): \(error)", category: .commands)
            }
        }
        return total
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024.0
        return String(format: "%.1f GB", gb)
    }

    private func fileTypeLabel(_ type: FileAttributeType?) -> String {
        switch type {
        case .typeDirectory: return "directory"
        case .typeRegular: return "file"
        case .typeSymbolicLink: return "symlink"
        default: return "unknown"
        }
    }
}
