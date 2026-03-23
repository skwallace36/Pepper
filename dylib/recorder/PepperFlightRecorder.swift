import Foundation

/// Always-on flight recorder that captures lightweight timeline events
/// from network, console, screen transitions, and command dispatch.
///
/// Auto-starts when Pepper connects. Events are stored in a bounded
/// ring buffer, queryable by time range and event type.
///
/// Per-simulator isolation is automatic — each simulator process gets
/// its own dylib instance with its own singleton.
final class PepperFlightRecorder {
    static let shared = PepperFlightRecorder()

    private let queue = DispatchQueue(label: "com.pepper.control.recorder", attributes: .concurrent)

    /// Ring buffer of timeline events.
    private var buffer: [TimelineEvent] = []

    /// Maximum buffer entries. Configurable via the timeline command.
    private(set) var bufferSize: Int = 2000

    /// Total events recorded (including evicted from buffer).
    private(set) var totalRecorded: Int = 0

    /// Whether recording is active (default: true — always on).
    private(set) var isRecording: Bool = true

    /// Which event types are enabled (default: all).
    private(set) var enabledTypes: Set<TimelineEventType> = Set(TimelineEventType.allCases)

    /// Whether install() has been called.
    private var installed = false

    private init() {}

    // MARK: - Lifecycle

    /// Install the flight recorder and auto-start network + console capture.
    /// Called once from PepperPlane.start(). Idempotent.
    func install() {
        guard !installed else { return }
        installed = true

        // Auto-start network interception (lightweight — URLProtocol canInit is a bool check)
        PepperNetworkInterceptor.shared.install()

        // Auto-start console capture (tees to original fd, minimal overhead)
        PepperConsoleInterceptor.shared.install()

        record(type: .command, summary: "Flight recorder started (buffer: \(bufferSize))")
        pepperLog.info("Flight recorder installed (buffer: \(bufferSize))", category: .lifecycle)
    }

    // MARK: - Recording

    /// Record an event into the ring buffer. Thread-safe.
    func record(type: TimelineEventType, summary: String, referenceId: String? = nil) {
        guard isRecording, enabledTypes.contains(type) else { return }

        let event = TimelineEvent(
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            type: type,
            summary: summary,
            referenceId: referenceId
        )

        queue.async(flags: .barrier) {
            if self.buffer.count >= self.bufferSize {
                self.buffer.removeFirst()
            }
            self.buffer.append(event)
            self.totalRecorded += 1
        }
    }

    // MARK: - Query

    /// Query timeline events with optional filters. Returns newest-last order.
    func query(
        limit: Int = 100,
        types: Set<TimelineEventType>? = nil,
        sinceMs: Int64? = nil,
        filter: String? = nil
    ) -> [TimelineEvent] {
        queue.sync {
            var results = buffer

            if let sinceMs = sinceMs {
                results = results.filter { $0.timestampMs >= sinceMs }
            }
            if let types = types {
                results = results.filter { types.contains($0.type) }
            }
            if let filter = filter, !filter.isEmpty {
                results = results.filter { $0.summary.localizedCaseInsensitiveContains(filter) }
            }

            return Array(results.suffix(limit))
        }
    }

    // MARK: - Configuration

    /// Update buffer size. If shrinking, oldest events are evicted.
    func setBufferSize(_ size: Int) {
        guard size > 0 else { return }
        queue.async(flags: .barrier) {
            self.bufferSize = size
            while self.buffer.count > size {
                self.buffer.removeFirst()
            }
        }
    }

    /// Enable or disable recording.
    func setRecording(_ enabled: Bool) {
        queue.async(flags: .barrier) {
            self.isRecording = enabled
        }
    }

    /// Set which event types are captured.
    func setEnabledTypes(_ types: Set<TimelineEventType>) {
        queue.async(flags: .barrier) {
            self.enabledTypes = types
        }
    }

    /// Clear the buffer.
    func clearBuffer() {
        queue.async(flags: .barrier) {
            self.buffer.removeAll()
        }
    }

    /// Current entry count.
    var entryCount: Int {
        queue.sync { buffer.count }
    }
}
