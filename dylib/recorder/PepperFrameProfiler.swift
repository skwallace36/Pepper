import Foundation
import QuartzCore
import UIKit

/// Measures UI frame performance using CADisplayLink.
/// Tracks frame timestamps, detects hitches (missed vsync deadlines),
/// and stores results in a bounded ring buffer.
///
/// Thread safety: concurrent dispatch queue with barrier writes (same pattern as FlightRecorder).
final class PepperFrameProfiler {
    static let shared = PepperFrameProfiler()

    private let queue = DispatchQueue(label: "com.pepper.control.frame-profiler", attributes: .concurrent)

    // MARK: - State

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frameTimes: [FrameSample] = []
    private var markers: [FrameMarker] = []
    private(set) var isRunning: Bool = false
    private var startTime: CFTimeInterval = 0

    /// Maximum frame samples to keep.
    private let maxSamples = 4000

    private init() {}

    // MARK: - Lifecycle

    /// Start frame profiling. Must be called on the main thread.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRunning else { return }

        queue.async(flags: .barrier) {
            self.frameTimes.removeAll()
            self.markers.removeAll()
            self.lastTimestamp = 0
            self.isRunning = true
        }

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        startTime = CACurrentMediaTime()
    }

    /// Stop frame profiling and return collected stats. Must be called on the main thread.
    func stop() -> FrameStats {
        dispatchPrecondition(condition: .onQueue(.main))
        displayLink?.invalidate()
        displayLink = nil

        let stats = computeStats()
        queue.async(flags: .barrier) {
            self.isRunning = false
        }
        return stats
    }

    /// Insert a named marker at the current time.
    func mark(_ label: String) {
        let ts = CACurrentMediaTime()
        queue.async(flags: .barrier) {
            self.markers.append(FrameMarker(
                label: label,
                timestamp: ts,
                offsetMs: (ts - self.startTime) * 1000
            ))
        }
        PepperFlightRecorder.shared.record(type: .command, summary: "perf:mark \(label)")
    }

    // MARK: - Display link callback

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTimestamp > 0 {
            let dt = now - lastTimestamp
            let dtMs = dt * 1000
            let sample = FrameSample(
                timestamp: now,
                frameTimeMs: dtMs,
                offsetMs: (now - startTime) * 1000
            )
            queue.async(flags: .barrier) {
                if self.frameTimes.count >= self.maxSamples {
                    self.frameTimes.removeFirst()
                }
                self.frameTimes.append(sample)
            }
        }
        lastTimestamp = now
    }

    // MARK: - Stats

    /// Compute statistics from collected frame samples.
    func computeStats() -> FrameStats {
        queue.sync {
            guard !frameTimes.isEmpty else {
                return FrameStats(
                    totalFrames: 0, durationMs: 0,
                    avgFrameTimeMs: 0, minFrameTimeMs: 0, maxFrameTimeMs: 0,
                    p95FrameTimeMs: 0, p99FrameTimeMs: 0,
                    droppedFrames: 0, hitchCount: 0,
                    hitchTimeMs: 0, hitchRatio: 0,
                    avgFps: 0, markers: markers
                )
            }

            let times = frameTimes.map { $0.frameTimeMs }
            let sorted = times.sorted()
            let count = sorted.count
            let total = times.reduce(0, +)
            let avg = total / Double(count)

            // Percentiles
            let p95 = sorted[min(Int(Double(count) * 0.95), count - 1)]
            let p99 = sorted[min(Int(Double(count) * 0.99), count - 1)]

            // Hitch detection: frame time > 16.67ms (missed 60fps vsync)
            let hitchThresholdMs = 16.67
            let hitches = times.filter { $0 > hitchThresholdMs }
            let hitchTimeTotal = hitches.reduce(0) { $0 + ($1 - hitchThresholdMs) }

            // Dropped frames: each hitch drops floor(dt / 16.67) - 1 frames
            let dropped = times.reduce(0) { acc, dt in
                let expected = Int(dt / hitchThresholdMs)
                return acc + max(0, expected - 1)
            }

            let durationMs = total
            let hitchRatio = durationMs > 0 ? hitchTimeTotal / durationMs : 0

            return FrameStats(
                totalFrames: count,
                durationMs: durationMs,
                avgFrameTimeMs: avg,
                minFrameTimeMs: sorted.first ?? 0,
                maxFrameTimeMs: sorted.last ?? 0,
                p95FrameTimeMs: p95,
                p99FrameTimeMs: p99,
                droppedFrames: dropped,
                hitchCount: hitches.count,
                hitchTimeMs: hitchTimeTotal,
                hitchRatio: hitchRatio,
                avgFps: avg > 0 ? 1000.0 / avg : 0,
                markers: markers
            )
        }
    }

    /// Current sample count.
    var sampleCount: Int {
        queue.sync { frameTimes.count }
    }

    /// Current marker count.
    var markerCount: Int {
        queue.sync { markers.count }
    }
}

// MARK: - Data types

struct FrameSample {
    let timestamp: CFTimeInterval
    let frameTimeMs: Double
    let offsetMs: Double
}

struct FrameMarker {
    let label: String
    let timestamp: CFTimeInterval
    let offsetMs: Double

    func toDictionary() -> [String: AnyCodable] {
        [
            "label": AnyCodable(label),
            "offset_ms": AnyCodable(round(offsetMs * 100) / 100),
        ]
    }
}

struct FrameStats {
    let totalFrames: Int
    let durationMs: Double
    let avgFrameTimeMs: Double
    let minFrameTimeMs: Double
    let maxFrameTimeMs: Double
    let p95FrameTimeMs: Double
    let p99FrameTimeMs: Double
    let droppedFrames: Int
    let hitchCount: Int
    let hitchTimeMs: Double
    let hitchRatio: Double
    let avgFps: Double
    let markers: [FrameMarker]

    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "total_frames": AnyCodable(totalFrames),
            "duration_ms": AnyCodable(round(durationMs * 100) / 100),
            "avg_frame_time_ms": AnyCodable(round(avgFrameTimeMs * 100) / 100),
            "min_frame_time_ms": AnyCodable(round(minFrameTimeMs * 100) / 100),
            "max_frame_time_ms": AnyCodable(round(maxFrameTimeMs * 100) / 100),
            "p95_frame_time_ms": AnyCodable(round(p95FrameTimeMs * 100) / 100),
            "p99_frame_time_ms": AnyCodable(round(p99FrameTimeMs * 100) / 100),
            "dropped_frames": AnyCodable(droppedFrames),
            "hitch_count": AnyCodable(hitchCount),
            "hitch_time_ms": AnyCodable(round(hitchTimeMs * 100) / 100),
            "hitch_ratio": AnyCodable(round(hitchRatio * 10000) / 10000),
            "avg_fps": AnyCodable(round(avgFps * 100) / 100),
        ]
        if !markers.isEmpty {
            dict["markers"] = AnyCodable(markers.map { AnyCodable($0.toDictionary()) })
        }
        return dict
    }
}
