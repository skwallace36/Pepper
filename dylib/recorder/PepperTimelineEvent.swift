import Foundation

/// Event types captured by the flight recorder.
enum TimelineEventType: String, Codable, CaseIterable {
    case network  // HTTP request completed
    case console  // Console log line (stdout/stderr)
    case screen  // VC appeared/disappeared
    case command  // Pepper command dispatched
    case render  // SwiftUI hosting view re-rendered
}

/// A lightweight event in the flight recorder timeline.
/// Kept small (~100 bytes) so thousands fit in the ring buffer with minimal memory.
struct TimelineEvent {
    let timestampMs: Int64
    let type: TimelineEventType
    let summary: String
    let referenceId: String?  // cross-reference to full data (network txn ID, etc.)

    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "timestamp_ms": AnyCodable(timestampMs),
            "type": AnyCodable(type.rawValue),
            "summary": AnyCodable(summary),
        ]
        if let referenceId = referenceId {
            dict["ref_id"] = AnyCodable(referenceId)
        }
        return dict
    }
}
