import Foundation
import MachO

/// Handles {"cmd": "frameworks"} — enumerate loaded dylibs/frameworks.
///
/// Parses Mach-O headers for each loaded image to extract version info,
/// UUIDs, and segment layout. Useful for understanding app composition
/// and detecting unexpected dependencies.
///
/// Actions:
///   - "list":   List all loaded images with names and versions (default).
///   - "detail": Detailed info for a single image. Params: name (substring match).
struct FrameworksHandler: PepperHandler {
    let commandName = "frameworks"
    let timeout: TimeInterval = 15.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "list"

        switch action {
        case "list":
            return handleList(command)
        case "detail":
            return handleDetail(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown frameworks action '\(action)'. Use list/detail.")
        }
    }

    // MARK: - List

    private func handleList(_ command: PepperCommand) -> PepperResponse {
        let filter = command.params?["filter"]?.stringValue?.lowercased()
        let count = _dyld_image_count()
        var items: [AnyCodable] = []

        for i in 0..<count {
            guard let nameCStr = _dyld_get_image_name(i) else { continue }
            let path = String(cString: nameCStr)
            let name = (path as NSString).lastPathComponent

            if let filter = filter, !name.lowercased().contains(filter) && !path.lowercased().contains(filter) {
                continue
            }

            var entry: [String: AnyCodable] = [
                "name": AnyCodable(name),
                "path": AnyCodable(path),
            ]

            if let header = _dyld_get_image_header(i) {
                let versions = extractVersions(header)
                for (k, v) in versions { entry[k] = v }
            }

            items.append(AnyCodable(entry))
        }

        return .list(id: command.id, "frameworks", items)
    }

    // MARK: - Detail

    private func handleDetail(_ command: PepperCommand) -> PepperResponse {
        guard let query = command.params?["name"]?.stringValue?.lowercased() else {
            return .error(id: command.id, message: "Missing 'name' param.")
        }

        let count = _dyld_image_count()
        for i in 0..<count {
            guard let nameCStr = _dyld_get_image_name(i) else { continue }
            let path = String(cString: nameCStr)
            let name = (path as NSString).lastPathComponent

            guard name.lowercased().contains(query) || path.lowercased().contains(query) else {
                continue
            }

            var data: [String: AnyCodable] = [
                "name": AnyCodable(name),
                "path": AnyCodable(path),
                "slide": AnyCodable(String(format: "0x%lx", _dyld_get_image_vmaddr_slide(i))),
            ]

            if let header = _dyld_get_image_header(i) {
                let versions = extractVersions(header)
                for (k, v) in versions { data[k] = v }

                let uuid = extractUUID(header)
                if let uuid = uuid { data["uuid"] = AnyCodable(uuid) }

                let segments = extractSegments(header)
                if !segments.isEmpty { data["segments"] = AnyCodable(segments) }

                if let buildVer = extractBuildVersion(header) {
                    for (k, v) in buildVer { data[k] = v }
                }
            }

            return .result(id: command.id, data)
        }

        return .error(id: command.id, message: "No loaded image matching '\(query)'.")
    }

    // MARK: - Mach-O Parsing

    private func extractVersions(_ header: UnsafePointer<mach_header>) -> [String: AnyCodable] {
        var result: [String: AnyCodable] = [:]
        enumerateLoadCommands(header) { cmd in
            if cmd.pointee.cmd == LC_ID_DYLIB {
                let dylibCmd = UnsafeRawPointer(cmd).bindMemory(to: dylib_command.self, capacity: 1)
                let current = dylibCmd.pointee.dylib.current_version
                let compat = dylibCmd.pointee.dylib.compatibility_version
                result["current_version"] = AnyCodable(formatDylibVersion(current))
                result["compat_version"] = AnyCodable(formatDylibVersion(compat))
            }
        }
        return result
    }

    private func extractUUID(_ header: UnsafePointer<mach_header>) -> String? {
        var uuidString: String?
        enumerateLoadCommands(header) { cmd in
            if cmd.pointee.cmd == LC_UUID {
                let uuidCmd = UnsafeRawPointer(cmd).bindMemory(to: uuid_command.self, capacity: 1)
                let bytes = uuidCmd.pointee.uuid
                uuidString = String(
                    format: "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                    bytes.0, bytes.1, bytes.2, bytes.3,
                    bytes.4, bytes.5, bytes.6, bytes.7,
                    bytes.8, bytes.9, bytes.10, bytes.11,
                    bytes.12, bytes.13, bytes.14, bytes.15)
            }
        }
        return uuidString
    }

    private func extractSegments(_ header: UnsafePointer<mach_header>) -> [[String: AnyCodable]] {
        var segments: [[String: AnyCodable]] = []
        enumerateLoadCommands(header) { cmd in
            if cmd.pointee.cmd == LC_SEGMENT_64 {
                let segCmd = UnsafeRawPointer(cmd).bindMemory(to: segment_command_64.self, capacity: 1)
                let name = withUnsafePointer(to: segCmd.pointee.segname) { ptr in
                    String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
                }
                segments.append([
                    "name": AnyCodable(name),
                    "vmaddr": AnyCodable(String(format: "0x%llx", segCmd.pointee.vmaddr)),
                    "vmsize": AnyCodable(segCmd.pointee.vmsize),
                    "filesize": AnyCodable(segCmd.pointee.filesize),
                ])
            }
        }
        return segments
    }

    private func extractBuildVersion(_ header: UnsafePointer<mach_header>) -> [String: AnyCodable]? {
        var result: [String: AnyCodable]?
        enumerateLoadCommands(header) { cmd in
            if cmd.pointee.cmd == LC_BUILD_VERSION {
                let buildCmd = UnsafeRawPointer(cmd).bindMemory(to: build_version_command.self, capacity: 1)
                let minos = buildCmd.pointee.minos
                let sdk = buildCmd.pointee.sdk
                result = [
                    "min_os": AnyCodable(formatBuildVersion(minos)),
                    "sdk_version": AnyCodable(formatBuildVersion(sdk)),
                ]
            }
        }
        return result
    }

    private func enumerateLoadCommands(
        _ header: UnsafePointer<mach_header>,
        _ body: (UnsafePointer<load_command>) -> Void
    ) {
        let is64 = header.pointee.magic == MH_MAGIC_64
        let headerSize = is64 ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size
        var cmdPtr = UnsafeRawPointer(header).advanced(by: headerSize)
            .assumingMemoryBound(to: load_command.self)

        for _ in 0..<header.pointee.ncmds {
            body(cmdPtr)
            cmdPtr = UnsafeRawPointer(cmdPtr).advanced(by: Int(cmdPtr.pointee.cmdsize))
                .assumingMemoryBound(to: load_command.self)
        }
    }

    // MARK: - Version Formatting

    private func formatDylibVersion(_ version: UInt32) -> String {
        let major = version >> 16
        let minor = (version >> 8) & 0xFF
        let patch = version & 0xFF
        return "\(major).\(minor).\(patch)"
    }

    private func formatBuildVersion(_ version: UInt32) -> String {
        let major = (version >> 16) & 0xFFFF
        let minor = (version >> 8) & 0xFF
        let patch = version & 0xFF
        return "\(major).\(minor).\(patch)"
    }
}
