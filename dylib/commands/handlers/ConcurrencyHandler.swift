import Foundation
import ObjectiveC

/// Handles {"cmd": "concurrency"} commands for Swift Concurrency runtime inspection.
///
/// Inspects the Swift Concurrency runtime: active Tasks, actor classes, executor state,
/// and structured concurrency diagnostics. Uses dlsym into libswift_Concurrency.dylib
/// for runtime metadata and ObjC runtime for actor class discovery.
///
/// Actions:
///   - "summary":  Overview — active task count, actor classes, MainActor status
///   - "actors":   List actor classes found via runtime metadata, with instance discovery
///   - "tasks":    Active task count and current task context info
///   - "cancel":   Cancel a task by address (for testing). Params: address
struct ConcurrencyHandler: PepperHandler {
    let commandName = "concurrency"
    let timeout: TimeInterval = 15.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "summary"

        switch action {
        case "summary":
            return handleSummary(command)
        case "actors":
            return handleActors(command)
        case "tasks":
            return handleTasks(command)
        case "cancel":
            return handleCancel(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown concurrency action '\(action)'. Use summary/actors/tasks/cancel.")
        }
    }

    // MARK: - Summary

    private func handleSummary(_ command: PepperCommand) -> PepperResponse {
        let runtime = SwiftConcurrencyRuntime.shared

        var data: [String: AnyCodable] = [
            "runtime_available": AnyCodable(runtime.available)
        ]

        // Active task count from debug symbol
        let taskCount = runtime.activeTaskCount
        if taskCount >= 0 {
            data["active_task_count"] = AnyCodable(taskCount)
        }

        // Actor class scan
        let actors = findActorClasses(limit: 50)
        data["actor_class_count"] = AnyCodable(actors.count)
        data["actor_classes"] = AnyCodable(actors.map { AnyCodable($0) })

        // MainActor status
        data["main_thread"] = AnyCodable(Thread.isMainThread)

        // Current task context
        if let taskPtr = runtime.currentTask {
            data["current_task_address"] = AnyCodable(String(format: "0x%lx", Int(bitPattern: taskPtr)))
            if let info = runtime.readTaskInfo(taskPtr) {
                data["current_task"] = AnyCodable(info)
            }
        } else {
            data["current_task"] = AnyCodable("none (not in async context)")
        }

        // GCD global queue info
        data["gcd_main_queue_pending"] = AnyCodable(estimateMainQueueDepth())

        return .ok(id: command.id, data: data)
    }

    // MARK: - Actors

    private func handleActors(_ command: PepperCommand) -> PepperResponse {
        let pattern = command.params?["pattern"]?.stringValue
        let limit = command.params?["limit"]?.intValue ?? 100

        var actors = findActorClasses(limit: 500)

        // Filter by pattern if provided
        if let pattern = pattern, !pattern.isEmpty {
            let lowerPattern = pattern.lowercased()
            actors = actors.filter { $0.lowercased().contains(lowerPattern) }
        }

        // Try to find instances for each actor class
        var actorDetails: [[String: AnyCodable]] = []
        for className in actors.prefix(limit) {
            var entry: [String: AnyCodable] = [
                "class": AnyCodable(className)
            ]

            // Check if it's a default actor (has built-in serial executor)
            if let cls = NSClassFromString(className) {
                let classPtr = unsafeBitCast(cls, to: UnsafeRawPointer.self)
                let flags = classPtr.load(fromByteOffset: 40, as: UInt32.self)
                entry["is_default_actor"] = AnyCodable((flags & 0x100) != 0)

                // Try singleton discovery
                if let (_, method) = findActorInstance(cls) {
                    entry["instance_found"] = AnyCodable(true)
                    entry["found_via"] = AnyCodable(method)
                } else {
                    entry["instance_found"] = AnyCodable(false)
                }
            }

            actorDetails.append(entry)
        }

        return .ok(
            id: command.id,
            data: [
                "total": AnyCodable(actors.count),
                "showing": AnyCodable(actorDetails.count),
                "actors": AnyCodable(actorDetails),
            ])
    }

    // MARK: - Tasks

    private func handleTasks(_ command: PepperCommand) -> PepperResponse {
        let runtime = SwiftConcurrencyRuntime.shared

        var data: [String: AnyCodable] = [
            "runtime_available": AnyCodable(runtime.available)
        ]

        let taskCount = runtime.activeTaskCount
        if taskCount >= 0 {
            data["active_task_count"] = AnyCodable(taskCount)
        } else {
            data["active_task_count"] = AnyCodable("unavailable (debug symbol not found)")
        }

        // Current task context
        if let taskPtr = runtime.currentTask {
            let address = String(format: "0x%lx", Int(bitPattern: taskPtr))
            data["current_task_address"] = AnyCodable(address)
            if let info = runtime.readTaskInfo(taskPtr) {
                data["current_task"] = AnyCodable(info)
            }
        } else {
            data["current_task"] = AnyCodable("none (handler runs on main dispatch queue, not in async context)")
        }

        // Provide available symbols for diagnostics
        data["symbols_loaded"] = AnyCodable([
            "swift_task_getCurrent": AnyCodable(runtime.taskGetCurrent != nil),
            "swift_concurrency_debug_asyncTaskCount": AnyCodable(runtime.asyncTaskCountPtr != nil),
            "swift_task_cancel": AnyCodable(runtime.taskCancel != nil),
        ])

        return .ok(id: command.id, data: data)
    }

    // MARK: - Cancel

    private func handleCancel(_ command: PepperCommand) -> PepperResponse {
        let runtime = SwiftConcurrencyRuntime.shared

        guard let taskCancel = runtime.taskCancel else {
            return .error(
                id: command.id,
                message: "swift_task_cancel symbol not available in this runtime.")
        }

        guard let addressStr = command.params?["address"]?.stringValue else {
            return .error(
                id: command.id,
                message: "Missing 'address' param. Provide a task address (hex string, e.g. '0x1234abcd').")
        }

        // Parse hex address
        let cleanAddress =
            addressStr.hasPrefix("0x")
            ? String(addressStr.dropFirst(2))
            : addressStr

        guard let addressValue = UInt(cleanAddress, radix: 16) else {
            return .error(
                id: command.id,
                message: "Invalid address '\(addressStr)'. Provide a hex address (e.g. '0x1234abcd').")
        }

        let taskPtr = UnsafeMutableRawPointer(bitPattern: addressValue)
        guard let ptr = taskPtr else {
            return .error(id: command.id, message: "Null address is not a valid task pointer.")
        }

        // Cancel the task — this is inherently unsafe but useful for testing
        taskCancel(ptr)

        return .ok(
            id: command.id,
            data: [
                "cancelled": AnyCodable(true),
                "address": AnyCodable(addressStr),
                "warning": AnyCodable(
                    "Task cancellation is cooperative — the task must check for cancellation to actually stop."),
            ])
    }

    // MARK: - Actor Class Discovery

    /// Find all actor classes in the ObjC runtime by checking Swift class metadata flags.
    private func findActorClasses(limit: Int) -> [String] {
        let count = Int(objc_getClassList(nil, 0))
        guard count > 0 else { return [] }

        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: count)
        let actualCount = Int(objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), Int32(count)))
        defer { buffer.deallocate() }

        var actors: [String] = []
        for i in 0..<actualCount {
            let cls: AnyClass = buffer[i]
            if isActorClass(cls) {
                actors.append(NSStringFromClass(cls))
            }
            if actors.count >= limit { break }
        }

        actors.sort()
        return actors
    }

    /// Check if a class is a Swift actor by reading the class metadata flags.
    /// Swift class metadata has ClassFlags at offset 40 (on 64-bit) with IsActor = 0x80.
    private func isActorClass(_ cls: AnyClass) -> Bool {
        guard isSwiftClass(cls) else { return false }
        let classPtr = unsafeBitCast(cls, to: UnsafeRawPointer.self)
        let flags = classPtr.load(fromByteOffset: 40, as: UInt32.self)
        return (flags & 0x80) != 0
    }

    /// Check if a class is a Swift class (not pure ObjC) by checking the data field tag bit.
    private func isSwiftClass(_ cls: AnyClass) -> Bool {
        let classPtr = unsafeBitCast(cls, to: UnsafeRawPointer.self)
        let data = classPtr.load(fromByteOffset: 32, as: UInt.self)
        // Bit 1 indicates Swift class in the class_ro_t pointer
        return (data & 0x2) != 0
    }

    /// Try to find a live instance of an actor class via singleton selectors.
    private func findActorInstance(_ cls: AnyClass) -> (AnyObject, String)? {
        let singletonSelectors = [
            "shared", "sharedInstance", "default", "defaultManager",
            "current", "main", "standard",
        ]
        for selName in singletonSelectors {
            let sel = NSSelectorFromString(selName)
            if class_getClassMethod(cls, sel) != nil {
                if let result = (cls as AnyObject).perform(sel)?.takeUnretainedValue() {
                    return (result, ".\(selName)")
                }
            }
        }
        return nil
    }

    // MARK: - GCD Introspection

    /// Estimate pending work items on the main queue.
    /// Uses a lightweight probe — enqueues a marker and checks if it runs immediately.
    private func estimateMainQueueDepth() -> String {
        // We can't reliably count pending main queue items without private API.
        // Instead, report whether the main run loop is busy.
        if let currentMode = RunLoop.main.currentMode {
            return "active (\(currentMode.rawValue))"
        }
        return "idle"
    }
}

// MARK: - Swift Concurrency Runtime API

/// Lazy-loaded function pointers into the Swift Concurrency runtime via dlsym.
/// Provides access to debug symbols for task counting, current task inspection,
/// and task cancellation.
private struct SwiftConcurrencyRuntime {
    typealias TaskGetCurrent = @convention(c) () -> UnsafeMutableRawPointer?
    typealias TaskCancel = @convention(c) (UnsafeMutableRawPointer) -> Void

    let taskGetCurrent: TaskGetCurrent?
    let asyncTaskCountPtr: UnsafePointer<Int>?
    let taskCancel: TaskCancel?
    let available: Bool

    static let shared: SwiftConcurrencyRuntime = {
        // Search all loaded images (the concurrency library is already loaded in-process)
        let handle = dlopen(nil, RTLD_NOW)

        let getCurrentSym = dlsym(handle, "swift_task_getCurrent")
        let taskCountSym = dlsym(handle, "swift_concurrency_debug_asyncTaskCount")
        let cancelSym = dlsym(handle, "swift_task_cancel")

        let api = SwiftConcurrencyRuntime(
            taskGetCurrent: getCurrentSym.map { unsafeBitCast($0, to: TaskGetCurrent.self) },
            asyncTaskCountPtr: taskCountSym?.assumingMemoryBound(to: Int.self),
            taskCancel: cancelSym.map { unsafeBitCast($0, to: TaskCancel.self) },
            available: getCurrentSym != nil || taskCountSym != nil
        )

        return api
    }()

    /// Read the global active task count. Returns -1 if symbol unavailable.
    var activeTaskCount: Int {
        asyncTaskCountPtr?.pointee ?? -1
    }

    /// Get the current async task pointer, if running in an async context.
    var currentTask: UnsafeMutableRawPointer? {
        taskGetCurrent?()
    }

    /// Read task metadata from a task pointer.
    /// Task layout (64-bit): HeapObject (16 bytes) + Job header (16 bytes) + Flags (4 bytes) + Id (4 bytes)
    func readTaskInfo(_ taskPtr: UnsafeMutableRawPointer) -> [String: AnyCodable]? {
        // Job flags are at offset 32 (after HeapObject 16 + SchedulerPrivate 16)
        // The flags contain priority in bits 0-7
        let flagsOffset = 32
        let flags = taskPtr.load(fromByteOffset: flagsOffset, as: UInt32.self)

        let priorityRaw = flags & 0xFF
        let priority = taskPriorityName(priorityRaw)
        let isChildTask = (flags & 0x100) != 0
        let isFuture = (flags & 0x200) != 0
        let isGroupChildTask = (flags & 0x400) != 0
        let isAsyncLetTask = (flags & 0x800) != 0

        // Task ID is at offset 36
        let taskId = taskPtr.load(fromByteOffset: 36, as: UInt32.self)

        var info: [String: AnyCodable] = [
            "id": AnyCodable(Int(taskId)),
            "priority": AnyCodable(priority),
            "priority_raw": AnyCodable(Int(priorityRaw)),
            "is_child_task": AnyCodable(isChildTask),
            "is_future": AnyCodable(isFuture),
            "is_group_child_task": AnyCodable(isGroupChildTask),
            "is_async_let_task": AnyCodable(isAsyncLetTask),
        ]

        // Check cancellation flag — stored in the task status at a further offset
        // Status flags are at offset 40 (after flags + id)
        let status = taskPtr.load(fromByteOffset: 40, as: UInt32.self)
        let isCancelled = (status & 0x1) != 0
        let isEscalated = (status & 0x2) != 0
        info["is_cancelled"] = AnyCodable(isCancelled)
        info["is_escalated"] = AnyCodable(isEscalated)

        return info
    }

    /// Convert a raw priority value to a human-readable name.
    private func taskPriorityName(_ raw: UInt32) -> String {
        switch raw {
        case 0x21: return "userInteractive"
        case 0x19: return "userInitiated"
        case 0x15: return "default"
        case 0x11: return "utility"
        case 0x09: return "background"
        case 0x00: return "unspecified"
        default: return "unknown(\(raw))"
        }
    }
}
