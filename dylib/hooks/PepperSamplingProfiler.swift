import Foundation
import MachO
import QuartzCore
import os

/// Sampling profiler that captures the main thread's stack at configurable intervals.
///
/// Runs a high-priority background thread that periodically suspends the main thread,
/// walks the frame pointer chain via Mach APIs, symbolicates with dladdr(), and stores
/// samples in a bounded ring buffer. Samples are aggregated into a flame-graph-style
/// profile on stop.
///
/// Uses the same thread suspension / frame walking / symbolication as PepperHangDetector
/// but at much higher frequency (default 1ms intervals).
final class PepperSamplingProfiler {
    static let shared = PepperSamplingProfiler()

    private var logger: Logger { PepperLogger.logger(category: "profiler") }

    // MARK: - Configuration

    /// Sampling interval in microseconds. Default 1000 (1ms).
    private(set) var intervalUs: Int = 1000

    /// Maximum samples to retain.
    private let maxSamples = 50000

    /// Maximum stack frames per sample.
    private let maxStackFrames = 32

    // MARK: - State

    private(set) var isRunning = false
    private var samplerThread: Thread?
    private var startTime: CFTimeInterval = 0

    /// Raw samples (newest last).
    private var samples: [ProfileSample] = []
    private let lock = NSLock()

    /// Total samples captured (including evicted).
    private(set) var totalSamples: Int = 0

    private init() {}

    // MARK: - Lifecycle

    func start(intervalUs: Int = 1000) {
        guard !isRunning else { return }
        self.intervalUs = max(100, intervalUs)  // floor at 100us
        isRunning = true
        totalSamples = 0

        lock.lock()
        samples.removeAll()
        samples.reserveCapacity(min(maxSamples, 10000))
        lock.unlock()

        startTime = CACurrentMediaTime()
        startSamplerThread()

        logger.info("Sampling profiler started (interval: \(self.intervalUs)μs)")
    }

    func stop() -> ProfileReport {
        guard isRunning else {
            return ProfileReport(
                durationMs: 0, totalSamples: 0, intervalUs: intervalUs,
                topFunctions: [], hotPaths: []
            )
        }
        isRunning = false
        // Sampler thread exits on next iteration

        let duration = (CACurrentMediaTime() - startTime) * 1000

        lock.lock()
        let captured = samples
        lock.unlock()

        let report = aggregate(samples: captured, durationMs: duration)
        logger.info("Profiler stopped. \(captured.count) samples over \(Int(duration))ms")
        return report
    }

    func getSamples(limit: Int = 100) -> [ProfileSample] {
        lock.lock()
        let result = Array(samples.suffix(limit))
        lock.unlock()
        return result
    }

    var sampleCount: Int {
        lock.lock()
        let count = samples.count
        lock.unlock()
        return count
    }

    // MARK: - Sampler Thread

    private func startSamplerThread() {
        let thread = Thread { [weak self] in
            self?.samplerLoop()
        }
        thread.name = "com.pepper.sampling-profiler"
        thread.qualityOfService = .userInteractive
        thread.threadPriority = 0.9
        samplerThread = thread
        thread.start()
    }

    private func samplerLoop() {
        let mainThread = getMainThreadPort()
        guard mainThread != mach_port_t(MACH_PORT_NULL) else {
            logger.error("Failed to get main thread port")
            isRunning = false
            return
        }

        while isRunning {
            let stack = captureStack(mainThread)
            if !stack.isEmpty {
                let sample = ProfileSample(
                    offsetUs: Int((CACurrentMediaTime() - startTime) * 1_000_000),
                    stack: stack
                )

                lock.lock()
                if samples.count >= maxSamples {
                    samples.removeFirst()
                }
                samples.append(sample)
                totalSamples += 1
                lock.unlock()
            }

            usleep(UInt32(intervalUs))
        }
    }

    // MARK: - Stack Capture

    private func captureStack(_ thread: mach_port_t) -> [StackAddress] {
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        defer { thread_resume(thread) }

        #if arch(arm64)
            return captureARM64(thread)
        #elseif arch(x86_64)
            return captureX86_64(thread)
        #else
            return []
        #endif
    }

    #if arch(arm64)
        private func captureARM64(_ thread: mach_port_t) -> [StackAddress] {
            var state = arm_thread_state64_t()
            var stateCount = mach_msg_type_number_t(
                MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)

            let kr = withUnsafeMutablePointer(to: &state) { statePtr in
                statePtr.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) { ptr in
                    thread_get_state(thread, ARM_THREAD_STATE64, ptr, &stateCount)
                }
            }
            guard kr == KERN_SUCCESS else { return [] }

            var addresses: [StackAddress] = []
            addresses.append(UInt(state.__pc))

            var fp = UInt(state.__fp)
            for _ in 0..<maxStackFrames {
                guard fp != 0, fp % UInt(MemoryLayout<UInt>.alignment) == 0 else { break }
                guard let framePtr = UnsafePointer<UInt>(bitPattern: fp) else { break }
                guard isReadable(UnsafeRawPointer(framePtr), size: MemoryLayout<UInt>.size * 2) else { break }

                let savedFp = framePtr.pointee
                let returnAddr = framePtr.advanced(by: 1).pointee & 0x0000_007F_FFFF_FFFF
                guard returnAddr > 0 else { break }

                addresses.append(returnAddr)
                guard savedFp > fp else { break }
                fp = savedFp
            }
            return addresses
        }
    #endif

    #if arch(x86_64)
        private func captureX86_64(_ thread: mach_port_t) -> [StackAddress] {
            var state = x86_thread_state64_t()
            var stateCount = mach_msg_type_number_t(
                MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)

            let kr = withUnsafeMutablePointer(to: &state) { statePtr in
                statePtr.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) { ptr in
                    thread_get_state(thread, x86_THREAD_STATE64, ptr, &stateCount)
                }
            }
            guard kr == KERN_SUCCESS else { return [] }

            var addresses: [StackAddress] = []
            addresses.append(UInt(state.__rip))

            var rbp = UInt(state.__rbp)
            for _ in 0..<maxStackFrames {
                guard rbp != 0, rbp % UInt(MemoryLayout<UInt>.alignment) == 0 else { break }
                guard let framePtr = UnsafePointer<UInt>(bitPattern: rbp) else { break }
                guard isReadable(UnsafeRawPointer(framePtr), size: MemoryLayout<UInt>.size * 2) else { break }

                let savedRbp = framePtr.pointee
                let returnAddr = framePtr.advanced(by: 1).pointee
                guard returnAddr > 0 else { break }

                addresses.append(returnAddr)
                guard savedRbp > rbp else { break }
                rbp = savedRbp
            }
            return addresses
        }
    #endif

    // MARK: - Helpers

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
        return mach_port_t(threads[0])
    }

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

    // MARK: - Aggregation

    /// Aggregate raw samples into a profile report with top functions and hot paths.
    private func aggregate(samples: [ProfileSample], durationMs: Double) -> ProfileReport {
        guard !samples.isEmpty else {
            return ProfileReport(
                durationMs: durationMs, totalSamples: 0, intervalUs: intervalUs,
                topFunctions: [], hotPaths: []
            )
        }

        // Count how often each address appears (self = top of stack, total = anywhere)
        var selfCounts: [StackAddress: Int] = [:]
        var totalCounts: [StackAddress: Int] = [:]

        for sample in samples {
            if let top = sample.stack.first {
                selfCounts[top, default: 0] += 1
            }
            // Deduplicate addresses within a single sample for total counts
            for addr in Set(sample.stack) {
                totalCounts[addr, default: 0] += 1
            }
        }

        // Symbolicate and build top functions list
        let total = samples.count
        var functions: [ProfileFunction] = []
        var symbolCache: [StackAddress: StackFrame] = [:]

        for (addr, selfCount) in selfCounts {
            let frame = symbolCache[addr] ?? symbolicate(addr)
            symbolCache[addr] = frame
            let totalCount = totalCounts[addr] ?? selfCount

            functions.append(
                ProfileFunction(
                    symbol: frame.symbol ?? String(format: "0x%lx", addr),
                    image: frame.image ?? "???",
                    selfCount: selfCount,
                    totalCount: totalCount,
                    selfPercent: Double(selfCount) / Double(total) * 100,
                    totalPercent: Double(totalCount) / Double(total) * 100
                ))
        }

        functions.sort { $0.selfCount > $1.selfCount }
        let topFunctions = Array(functions.prefix(30))

        // Build hot paths — most common full stack traces (symbolicated)
        var pathCounts: [String: (count: Int, stack: [String])] = [:]
        for sample in samples {
            let symbolicated = sample.stack.prefix(8).map { addr -> String in
                let frame = symbolCache[addr] ?? symbolicate(addr)
                symbolCache[addr] = frame
                return frame.symbol ?? String(format: "0x%lx", addr)
            }
            let key = symbolicated.joined(separator: " → ")
            if let existing = pathCounts[key] {
                pathCounts[key] = (count: existing.count + 1, stack: existing.stack)
            } else {
                pathCounts[key] = (count: 1, stack: Array(symbolicated))
            }
        }

        let hotPaths = pathCounts.values
            .sorted { $0.count > $1.count }
            .prefix(10)
            .map { ProfileHotPath(count: $0.count, percent: Double($0.count) / Double(total) * 100, stack: $0.stack) }

        return ProfileReport(
            durationMs: durationMs,
            totalSamples: total,
            intervalUs: intervalUs,
            topFunctions: topFunctions,
            hotPaths: Array(hotPaths)
        )
    }

    private func symbolicate(_ address: UInt) -> StackFrame {
        var info = Dl_info()
        let found = dladdr(UnsafeRawPointer(bitPattern: address), &info)
        guard found != 0 else {
            return StackFrame(address: address, symbol: nil, image: nil, offset: 0)
        }
        let symbol = info.dli_sname.map { String(cString: $0) }
        let image = info.dli_fname.map { fname -> String in
            (String(cString: fname) as NSString).lastPathComponent
        }
        let offset = address - UInt(bitPattern: info.dli_saddr)
        return StackFrame(address: address, symbol: symbol, image: image, offset: offset)
    }
}

// MARK: - Data Types

typealias StackAddress = UInt

struct ProfileSample {
    /// Microseconds since profiling started.
    let offsetUs: Int
    /// Stack addresses, top-of-stack first.
    let stack: [StackAddress]
}

struct ProfileFunction {
    let symbol: String
    let image: String
    let selfCount: Int
    let totalCount: Int
    let selfPercent: Double
    let totalPercent: Double

    func toDictionary() -> [String: AnyCodable] {
        [
            "symbol": AnyCodable(symbol),
            "image": AnyCodable(image),
            "self": AnyCodable(selfCount),
            "total": AnyCodable(totalCount),
            "self_pct": AnyCodable(String(format: "%.1f%%", selfPercent)),
            "total_pct": AnyCodable(String(format: "%.1f%%", totalPercent)),
        ]
    }
}

struct ProfileHotPath {
    let count: Int
    let percent: Double
    let stack: [String]

    func toDictionary() -> [String: AnyCodable] {
        [
            "count": AnyCodable(count),
            "percent": AnyCodable(String(format: "%.1f%%", percent)),
            "path": AnyCodable(stack.joined(separator: " → ")),
        ]
    }
}

struct ProfileReport {
    let durationMs: Double
    let totalSamples: Int
    let intervalUs: Int
    let topFunctions: [ProfileFunction]
    let hotPaths: [ProfileHotPath]

    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "duration_ms": AnyCodable(Int(durationMs)),
            "total_samples": AnyCodable(totalSamples),
            "interval_us": AnyCodable(intervalUs),
            "effective_rate_hz": AnyCodable(
                durationMs > 0 ? Int(Double(totalSamples) / (durationMs / 1000.0)) : 0),
        ]

        dict["top_functions"] = AnyCodable(topFunctions.map { AnyCodable($0.toDictionary()) })
        dict["hot_paths"] = AnyCodable(hotPaths.map { AnyCodable($0.toDictionary()) })

        // Human-readable summary
        var lines: [String] = []
        lines.append("Profile: \(totalSamples) samples over \(Int(durationMs))ms (\(intervalUs)μs interval)")
        lines.append("")
        lines.append("Top functions (by self time):")
        for fn in topFunctions.prefix(15) {
            lines.append(
                String(format: "  %5.1f%%  %5.1f%%  %@  (%@)", fn.selfPercent, fn.totalPercent, fn.symbol, fn.image))
        }
        if !hotPaths.isEmpty {
            lines.append("")
            lines.append("Hot paths:")
            for path in hotPaths.prefix(5) {
                lines.append(
                    String(
                        format: "  %5.1f%% (%d samples)  %@", path.percent, path.count,
                        path.stack.joined(separator: " → ")))
            }
        }
        dict["summary"] = AnyCodable(lines.joined(separator: "\n"))

        return dict
    }
}
