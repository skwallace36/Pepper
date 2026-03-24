import Foundation
import os

/// Captures app stdout (print) and stderr (NSLog) output into a ring buffer for the `console` command.
/// Redirects both through pipes, reads lines on background threads, stores them
/// in a shared circular buffer, and tee's output to the originals so Xcode console still works.
///
/// Usage:
///   PepperConsoleInterceptor.shared.install()
///   // ... app logs to stderr/NSLog ...
///   let lines = PepperConsoleInterceptor.shared.recentLines(limit: 50)
///   PepperConsoleInterceptor.shared.uninstall()
final class PepperConsoleInterceptor {
    static let shared = PepperConsoleInterceptor()

    private let queue = DispatchQueue(label: "com.pepper.control.console", attributes: .concurrent)

    /// Whether capture is active.
    private(set) var isActive = false

    /// Ring buffer of captured lines.
    private var buffer: [ConsoleEntry] = []
    private(set) var bufferSize: Int = 1000

    /// Total lines captured (including evicted).
    private(set) var totalCaptured: Int = 0

    /// Original file descriptors (saved before redirect).
    private var savedStderrFD: Int32 = -1
    private var savedStdoutFD: Int32 = -1

    /// Pipes for redirect.
    private var stderrPipeFDs: (read: Int32, write: Int32) = (-1, -1)
    private var stdoutPipeFDs: (read: Int32, write: Int32) = (-1, -1)

    /// Background reader threads.
    private var stderrReaderThread: Thread?
    private var stdoutReaderThread: Thread?

    private init() {}

    // MARK: - Types

    struct ConsoleEntry {
        let timestampMs: Int64
        let message: String
        let source: String  // "stdout" or "stderr"
    }

    // MARK: - Lifecycle

    /// Start capturing stdout + stderr. Idempotent — no-op if already active.
    func install(bufferSize: Int? = nil) {
        queue.async(flags: .barrier) {
            guard !self.isActive else { return }

            if let size = bufferSize, size > 0 {
                self.bufferSize = size
            }

            // --- stderr ---
            self.savedStderrFD = dup(STDERR_FILENO)
            guard self.savedStderrFD >= 0 else {
                pepperLog.error("Console: failed to dup stderr", category: .bridge)
                return
            }
            var stderrFDs: [Int32] = [0, 0]
            guard pipe(&stderrFDs) == 0 else {
                pepperLog.error("Console: failed to create stderr pipe", category: .bridge)
                close(self.savedStderrFD)
                self.savedStderrFD = -1
                return
            }
            self.stderrPipeFDs = (read: stderrFDs[0], write: stderrFDs[1])
            dup2(stderrFDs[1], STDERR_FILENO)

            let stderrThread = Thread { [weak self] in
                self?.readLoop(readFD: stderrFDs[0], originalFD: self?.savedStderrFD ?? -1, source: "stderr")
            }
            stderrThread.name = "com.pepper.console-stderr"
            stderrThread.qualityOfService = .utility
            self.stderrReaderThread = stderrThread
            stderrThread.start()

            // --- stdout (captures Swift print()) ---
            self.savedStdoutFD = dup(STDOUT_FILENO)
            if self.savedStdoutFD >= 0 {
                var stdoutFDs: [Int32] = [0, 0]
                if pipe(&stdoutFDs) == 0 {
                    self.stdoutPipeFDs = (read: stdoutFDs[0], write: stdoutFDs[1])
                    dup2(stdoutFDs[1], STDOUT_FILENO)

                    let stdoutThread = Thread { [weak self] in
                        self?.readLoop(readFD: stdoutFDs[0], originalFD: self?.savedStdoutFD ?? -1, source: "stdout")
                    }
                    stdoutThread.name = "com.pepper.console-stdout"
                    stdoutThread.qualityOfService = .utility
                    self.stdoutReaderThread = stdoutThread
                    stdoutThread.start()
                }
            }

            self.isActive = true
            pepperLog.info("Console capture started (buffer: \(self.bufferSize), stdout+stderr)", category: .bridge)
        }
    }

    /// Stop capturing. Restores original stdout + stderr.
    func uninstall() {
        queue.async(flags: .barrier) {
            guard self.isActive else { return }
            self.isActive = false

            // Restore original stderr
            if self.savedStderrFD >= 0 {
                dup2(self.savedStderrFD, STDERR_FILENO)
                close(self.savedStderrFD)
                self.savedStderrFD = -1
            }
            if self.stderrPipeFDs.write >= 0 {
                close(self.stderrPipeFDs.write)
                self.stderrPipeFDs.write = -1
            }
            let stderrReadFD = self.stderrPipeFDs.read
            self.stderrPipeFDs.read = -1

            // Restore original stdout
            if self.savedStdoutFD >= 0 {
                dup2(self.savedStdoutFD, STDOUT_FILENO)
                close(self.savedStdoutFD)
                self.savedStdoutFD = -1
            }
            if self.stdoutPipeFDs.write >= 0 {
                close(self.stdoutPipeFDs.write)
                self.stdoutPipeFDs.write = -1
            }
            let stdoutReadFD = self.stdoutPipeFDs.read
            self.stdoutPipeFDs.read = -1

            // Close read ends after a short delay to let readers drain
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                if stderrReadFD >= 0 { close(stderrReadFD) }
                if stdoutReadFD >= 0 { close(stdoutReadFD) }
            }

            self.stderrReaderThread = nil
            self.stdoutReaderThread = nil

            pepperLog.info("Console capture stopped (total captured: \(self.totalCaptured))", category: .bridge)
        }
    }

    // MARK: - Read Loop

    private func readLoop(readFD: Int32, originalFD: Int32, source: String) {
        let bufSize = 4096
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { readBuf.deallocate() }

        var partialLine = ""

        while true {
            let bytesRead = read(readFD, readBuf, bufSize)
            guard bytesRead > 0 else { break }  // pipe closed or error

            let data = Data(bytes: readBuf, count: bytesRead)

            // Tee to original fd so Xcode console still works
            if originalFD >= 0 {
                data.withUnsafeBytes { buf in
                    if let ptr = buf.baseAddress {
                        _ = Darwin.write(originalFD, ptr, bytesRead)
                    }
                }
            }

            // Split by newlines and buffer
            guard let chunk = String(data: data, encoding: .utf8) else { continue }
            let combined = partialLine + chunk
            var lines = combined.components(separatedBy: "\n")

            // Last element is either empty (ended with \n) or a partial line
            partialLine = lines.removeLast()

            let now = Int64(Date().timeIntervalSince1970 * 1000)
            for line in lines where !line.isEmpty {
                let entry = ConsoleEntry(timestampMs: now, message: line, source: source)
                appendEntry(entry)
            }
        }

        // Flush any remaining partial line
        if !partialLine.isEmpty {
            let entry = ConsoleEntry(
                timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                message: partialLine,
                source: source
            )
            appendEntry(entry)
        }
    }

    private func appendEntry(_ entry: ConsoleEntry) {
        queue.async(flags: .barrier) {
            if self.buffer.count >= self.bufferSize {
                self.buffer.removeFirst()
            }
            self.buffer.append(entry)
            self.totalCaptured += 1
        }

        // Record to flight recorder (first 120 chars)
        let truncated =
            entry.message.count > 120
            ? String(entry.message.prefix(120)) + "..."
            : entry.message
        PepperFlightRecorder.shared.record(type: .console, summary: "[\(entry.source)] \(truncated)")

        // Broadcast event for real-time streaming
        let event = PepperEvent(
            event: "console",
            data: [
                "timestamp_ms": AnyCodable(entry.timestampMs),
                "message": AnyCodable(entry.message),
                "source": AnyCodable(entry.source),
            ])
        DispatchQueue.main.async {
            PepperPlane.shared.broadcast(event)
        }
    }

    // MARK: - Query

    /// Get recent console lines, optionally filtered by substring.
    func recentLines(limit: Int = 50, filter: String? = nil, sinceMs: Int64? = nil) -> [[String: AnyCodable]] {
        queue.sync {
            var results = buffer
            if let sinceMs = sinceMs {
                results = results.filter { $0.timestampMs >= sinceMs }
            }
            if let filter = filter, !filter.isEmpty {
                results = results.filter { $0.message.localizedCaseInsensitiveContains(filter) }
            }
            return Array(results.suffix(limit)).map { entry in
                [
                    "timestamp_ms": AnyCodable(entry.timestampMs),
                    "message": AnyCodable(entry.message),
                    "source": AnyCodable(entry.source),
                ]
            }
        }
    }

    /// Number of entries in the buffer.
    var entryCount: Int {
        queue.sync { buffer.count }
    }

    /// Clear the buffer.
    func clearBuffer() {
        queue.async(flags: .barrier) {
            self.buffer.removeAll()
        }
    }
}
