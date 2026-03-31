import Foundation
import MachO
import QuartzCore
import os

/// Detects main thread hangs and captures symbolicated stack traces.
///
/// Uses a background watchdog thread that periodically pings the main thread.
/// When a hang is detected (main thread doesn't respond within the threshold),
/// suspends the main thread via Mach APIs, walks the frame pointer chain to
/// capture return addresses, symbolicates via dladdr(), then resumes.
///
/// Also uses CFRunLoopObserver to measure run loop iteration durations for
/// precise hang attribution within RunLoop iterations.
final class PepperHangDetector {
    static let shared = PepperHangDetector()

    private var logger: Logger { PepperLogger.logger(category: "hang-detector") }

    // MARK: - Configuration

    /// Hang threshold in milliseconds. Main thread unresponsive longer than this triggers capture.
    private(set) var thresholdMs: Int = 250

    /// Maximum number of hang events to retain.
    private let maxHangEvents = 50

    /// Maximum stack frames to capture per hang.
    private let maxStackFrames = 64

    // MARK: - State

    private(set) var isRunning = false
    private var watchdogThread: Thread?
    private var runLoopObserver: CFRunLoopObserver?

    /// Atomic flag toggled by main thread to signal liveness.
    private var _mainThreadAlive = ManagedAtomicBool(false)

    /// Recorded hang events (newest first).
    private var hangEvents: [HangEvent] = []
    private let lock = NSLock()

    /// Run loop iteration timing.
    private var runLoopIterationStart: CFTimeInterval = 0

    /// Total hangs detected since start.
    private(set) var totalHangsDetected: Int = 0

    private init() {}

    // MARK: - Lifecycle

    /// Start hang detection. Configurable threshold in ms (default 250).
    func start(thresholdMs: Int = 250) {
        guard !isRunning else { return }
        self.thresholdMs = max(50, thresholdMs)  // floor at 50ms
        isRunning = true
        totalHangsDetected = 0

        installRunLoopObserver()
        startWatchdogThread()

        logger.info("Hang detector started (threshold: \(self.thresholdMs)ms)")
    }

    /// Stop hang detection.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        removeRunLoopObserver()
        // Watchdog thread exits on next iteration when isRunning == false

        logger.info("Hang detector stopped. Total hangs: \(self.totalHangsDetected)")
    }

    /// Clear recorded hang events.
    func clearEvents() {
        lock.lock()
        hangEvents.removeAll()
        lock.unlock()
    }

    /// Get recorded hang events.
    func getEvents(limit: Int = 20) -> [HangEvent] {
        lock.lock()
        let events = Array(hangEvents.prefix(limit))
        lock.unlock()
        return events
    }

    // MARK: - Watchdog Thread

    private func startWatchdogThread() {
        let thread = Thread { [weak self] in
            self?.watchdogLoop()
        }
        thread.name = "com.pepper.hang-detector"
        thread.qualityOfService = .userInitiated
        watchdogThread = thread
        thread.start()
    }

    private func watchdogLoop() {
        let checkInterval = TimeInterval(thresholdMs) / 1000.0

        while isRunning {
            // Reset the liveness flag
            _mainThreadAlive.store(false)

            // Ask main thread to set the flag
            DispatchQueue.main.async { [weak self] in
                self?._mainThreadAlive.store(true)
            }

            // Wait for the threshold duration
            Thread.sleep(forTimeInterval: checkInterval)

            guard isRunning else { break }

            // If main thread didn't respond, it's hung
            if !_mainThreadAlive.load() {
                let stack = captureMainThreadStack()
                let event = HangEvent(
                    timestamp: Date(),
                    durationEstimateMs: thresholdMs,
                    stack: stack,
                    dispatchQueueDepth: PepperDispatchTracker.shared.pendingBlockCount
                )

                lock.lock()
                hangEvents.insert(event, at: 0)
                if hangEvents.count > maxHangEvents {
                    hangEvents.removeLast()
                }
                totalHangsDetected += 1
                lock.unlock()

                logger.warning("Main thread hang detected (\(self.thresholdMs)ms). Stack depth: \(stack.count)")
                PepperFlightRecorder.shared.record(
                    type: .command,
                    summary: "hang:\(self.thresholdMs)ms frames=\(stack.count)"
                )

                // Wait for the hang to resolve before checking again
                // to avoid flooding with duplicate events for the same hang
                while isRunning && !_mainThreadAlive.load() {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
    }

    // MARK: - Stack Capture via Mach Thread API

    private func captureMainThreadStack() -> [StackFrame] {
        // Get the main thread's Mach port
        let mainThread = getMainThreadPort()
        guard mainThread != mach_port_t(MACH_PORT_NULL) else {
            logger.error("Failed to get main thread Mach port")
            return []
        }

        var frames: [StackFrame] = []

        #if arch(arm64)
            frames = captureARM64Stack(mainThread)
        #elseif arch(x86_64)
            frames = captureX86_64Stack(mainThread)
        #endif

        return frames
    }

    /// Get the Mach thread port for the main thread.
    private func getMainThreadPort() -> mach_port_t {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadList, threadCount > 0 else {
            return mach_port_t(MACH_PORT_NULL)
        }
        defer {
            let size = vm_size_t(MemoryLayout<thread_act_t>.stride * Int(threadCount))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), size)
        }

        // Thread 0 is the main thread in Darwin
        return mach_port_t(threads[0])
    }

    #if arch(arm64)
        private func captureARM64Stack(_ thread: mach_port_t) -> [StackFrame] {
            // Suspend the thread to safely read its state
            guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
            defer { thread_resume(thread) }

            var state = arm_thread_state64_t()
            var stateCount = mach_msg_type_number_t(
                MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)

            let kr = withUnsafeMutablePointer(to: &state) { statePtr in
                statePtr.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) { ptr in
                    thread_get_state(thread, ARM_THREAD_STATE64, ptr, &stateCount)
                }
            }

            guard kr == KERN_SUCCESS else { return [] }

            var frames: [StackFrame] = []

            // First frame: current PC
            let pc = UInt(state.__pc)
            frames.append(symbolicate(pc))

            // Walk frame pointer chain (x29 / fp register)
            var fp = UInt(state.__fp)

            for _ in 0..<maxStackFrames {
                guard fp != 0, fp % UInt(MemoryLayout<UInt>.alignment) == 0 else { break }

                // Each frame: [saved_fp, return_address]
                let framePtr = UnsafePointer<UInt>(bitPattern: fp)
                guard let framePtr = framePtr else { break }

                // Validate the pointer is readable
                guard isReadable(UnsafeRawPointer(framePtr), size: MemoryLayout<UInt>.size * 2) else { break }

                let savedFp = framePtr.pointee
                let returnAddr = framePtr.advanced(by: 1).pointee

                // Strip PAC bits on arm64e (top byte masking)
                let cleanAddr = returnAddr & 0x0000_007F_FFFF_FFFF
                guard cleanAddr > 0 else { break }

                frames.append(symbolicate(cleanAddr))

                // Move to parent frame
                guard savedFp > fp else { break }  // Stack grows down; fp should increase going up
                fp = savedFp
            }

            return frames
        }
    #endif

    #if arch(x86_64)
        private func captureX86_64Stack(_ thread: mach_port_t) -> [StackFrame] {
            guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
            defer { thread_resume(thread) }

            var state = x86_thread_state64_t()
            var stateCount = mach_msg_type_number_t(
                MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)

            let kr = withUnsafeMutablePointer(to: &state) { statePtr in
                statePtr.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) { ptr in
                    thread_get_state(thread, x86_THREAD_STATE64, ptr, &stateCount)
                }
            }

            guard kr == KERN_SUCCESS else { return [] }

            var frames: [StackFrame] = []

            // First frame: current RIP
            let rip = UInt(state.__rip)
            frames.append(symbolicate(rip))

            // Walk frame pointer chain (RBP)
            var rbp = UInt(state.__rbp)

            for _ in 0..<maxStackFrames {
                guard rbp != 0, rbp % UInt(MemoryLayout<UInt>.alignment) == 0 else { break }

                let framePtr = UnsafePointer<UInt>(bitPattern: rbp)
                guard let framePtr = framePtr else { break }
                guard isReadable(UnsafeRawPointer(framePtr), size: MemoryLayout<UInt>.size * 2) else { break }

                let savedRbp = framePtr.pointee
                let returnAddr = framePtr.advanced(by: 1).pointee
                guard returnAddr > 0 else { break }

                frames.append(symbolicate(returnAddr))

                guard savedRbp > rbp else { break }
                rbp = savedRbp
            }

            return frames
        }
    #endif

    // MARK: - Symbolication

    private func symbolicate(_ address: UInt) -> StackFrame {
        var info = Dl_info()
        let found = dladdr(UnsafeRawPointer(bitPattern: address), &info)

        guard found != 0 else {
            return StackFrame(
                address: address,
                symbol: nil,
                image: nil,
                offset: 0
            )
        }

        let symbol = info.dli_sname.map { String(cString: $0) }
        let image = info.dli_fname.map { fname -> String in
            let path = String(cString: fname)
            return (path as NSString).lastPathComponent
        }
        let offset = address - UInt(bitPattern: info.dli_saddr)

        return StackFrame(
            address: address,
            symbol: symbol,
            image: image,
            offset: offset
        )
    }

    /// Check if a memory region is readable (avoid crashing on bad pointers).
    private func isReadable(_ ptr: UnsafeRawPointer, size: Int) -> Bool {
        var data = vm_offset_t(0)
        var dataCnt: mach_msg_type_number_t = 0
        let kr = vm_read(
            mach_task_self_,
            vm_address_t(bitPattern: ptr),
            vm_size_t(size),
            &data,
            &dataCnt
        )
        if kr == KERN_SUCCESS {
            vm_deallocate(mach_task_self_, data, vm_size_t(dataCnt))
            return true
        }
        return false
    }

    // MARK: - Run Loop Observer

    private func installRunLoopObserver() {
        let activities: CFRunLoopActivity = [.beforeSources, .afterWaiting]

        runLoopObserver = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities.rawValue,
            true,  // repeats
            0  // order
        ) { [weak self] _, activity in
            guard let self = self else { return }
            let now = CACurrentMediaTime()

            switch activity {
            case .beforeSources:
                // Starting a run loop iteration
                self.runLoopIterationStart = now
            case .afterWaiting:
                // Woke up from waiting — track previous iteration if we have a start
                if self.runLoopIterationStart > 0 {
                    let durationMs = (now - self.runLoopIterationStart) * 1000
                    if durationMs > Double(self.thresholdMs) {
                        self.logger.debug("Slow run loop iteration: \(Int(durationMs))ms")
                    }
                }
                self.runLoopIterationStart = now
            default:
                break
            }
        }

        if let observer = runLoopObserver {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private func removeRunLoopObserver() {
        if let observer = runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            runLoopObserver = nil
        }
    }
}

// MARK: - Data Types

struct StackFrame {
    let address: UInt
    let symbol: String?
    let image: String?
    let offset: UInt

    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "address": AnyCodable(String(format: "0x%lx", address))
        ]
        if let symbol = symbol {
            dict["symbol"] = AnyCodable(symbol)
        }
        if let image = image {
            dict["image"] = AnyCodable(image)
        }
        if offset > 0 {
            dict["offset"] = AnyCodable(Int(offset))
        }
        return dict
    }

    /// Human-readable single-line representation.
    var description: String {
        let sym = symbol ?? "???"
        let img = image ?? "???"
        return "\(img)  \(sym) + \(offset)"
    }
}

struct HangEvent {
    let timestamp: Date
    let durationEstimateMs: Int
    let stack: [StackFrame]
    let dispatchQueueDepth: Int

    func toDictionary() -> [String: AnyCodable] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var dict: [String: AnyCodable] = [
            "timestamp": AnyCodable(formatter.string(from: timestamp)),
            "duration_estimate_ms": AnyCodable(durationEstimateMs),
            "dispatch_queue_depth": AnyCodable(dispatchQueueDepth),
            "stack_depth": AnyCodable(stack.count),
        ]

        // Include full symbolicated stack
        dict["stack"] = AnyCodable(stack.map { AnyCodable($0.toDictionary()) })

        // Human-readable stack trace string
        let traceLines = stack.enumerated().map { i, frame in
            "\(i)  \(frame.description)"
        }
        dict["stack_trace"] = AnyCodable(traceLines.joined(separator: "\n"))

        return dict
    }
}

// MARK: - Lock-Free Atomic Bool

/// Minimal atomic boolean using os_unfair_lock.
private final class ManagedAtomicBool {
    private var _value: Bool
    private var _lock = os_unfair_lock()

    init(_ value: Bool) {
        _value = value
    }

    func load() -> Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _value
    }

    func store(_ newValue: Bool) {
        os_unfair_lock_lock(&_lock)
        _value = newValue
        os_unfair_lock_unlock(&_lock)
    }
}
