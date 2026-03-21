import UIKit
import os

/// Handles {"cmd": "watch"} commands.
/// Registers a background poll that tracks a specific element or region for changes
/// and pushes updates over WebSocket when the watched thing changes.
///
/// Watch targets:
///   - `label`: Watch a specific element by accessibility label
///   - `point`: Watch whatever element is at a screen coordinate
///   - `region`: Watch a rectangular area for any element changes
///
/// Returns immediately with a `watch_id`. Changes are pushed as `watch_update` events.
struct WatchHandler: PepperHandler {
    let commandName = "watch"
    private var logger: Logger { PepperLogger.logger(category: "watch") }

    func handle(_ command: PepperCommand) -> PepperResponse {
        let params = command.params

        let intervalMs = params?["interval_ms"]?.intValue ?? 200
        let timeoutMs = params?["timeout_ms"]?.intValue ?? 30000

        let target: WatchTarget
        if let label = params?["label"]?.stringValue {
            let exact = params?["exact"]?.boolValue ?? false
            target = .label(text: label, exact: exact)
        } else if let pointDict = params?["point"]?.value as? [String: AnyCodable],
                  let x = pointDict["x"]?.doubleValue,
                  let y = pointDict["y"]?.doubleValue {
            target = .point(CGPoint(x: x, y: y))
        } else if let regionDict = params?["region"]?.value as? [String: AnyCodable],
                  let x = regionDict["x"]?.doubleValue,
                  let y = regionDict["y"]?.doubleValue,
                  let w = regionDict["w"]?.doubleValue,
                  let h = regionDict["h"]?.doubleValue {
            target = .region(CGRect(x: x, y: y, width: w, height: h))
        } else {
            return .error(id: command.id, message: "Missing watch target. Provide: label, point, or region")
        }

        let watchID = WatchRegistry.shared.nextID()
        let initialSnapshot = takeSnapshot(target: target)

        let watch = WatchEntry(
            id: watchID,
            target: target,
            intervalMs: intervalMs,
            timeoutMs: timeoutMs,
            lastSnapshot: initialSnapshot,
            startTime: Date()
        )

        WatchRegistry.shared.register(watch)
        startPolling(watch: watch)

        logger.info("Watch \(watchID) started: \(String(describing: target)), interval=\(intervalMs)ms, timeout=\(timeoutMs)ms")

        return .ok(id: command.id, data: [
            "watch_id": AnyCodable(watchID),
            "initial": AnyCodable(initialSnapshot?.toDictionary() ?? [:])
        ])
    }

    // MARK: - Polling

    private func startPolling(watch: WatchEntry) {
        let interval = DispatchTimeInterval.milliseconds(watch.intervalMs)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)

        timer.setEventHandler { [logger] in
            guard let current = WatchRegistry.shared.get(watch.id) else {
                timer.cancel()
                return
            }

            // Check timeout
            let elapsed = Date().timeIntervalSince(current.startTime)
            if elapsed * 1000 >= Double(current.timeoutMs) {
                logger.info("Watch \(watch.id) timed out after \(Int(elapsed * 1000))ms")
                WatchRegistry.shared.remove(watch.id)
                timer.cancel()

                // Push timeout event
                let event = PepperEvent(event: "watch_update", data: [
                    "watch_id": AnyCodable(watch.id),
                    "change": AnyCodable("timeout"),
                    "elapsed_ms": AnyCodable(Int(elapsed * 1000))
                ])
                PepperPlane.shared.broadcast(event)
                return
            }

            // Take new snapshot and compare
            let newSnapshot = self.takeSnapshot(target: current.target)
            let change = self.detectChange(previous: current.lastSnapshot, current: newSnapshot)

            if let change = change {
                let elapsedMs = Int(elapsed * 1000)
                var eventData: [String: AnyCodable] = [
                    "watch_id": AnyCodable(watch.id),
                    "change": AnyCodable(change),
                    "elapsed_ms": AnyCodable(elapsedMs)
                ]

                if let snap = newSnapshot {
                    eventData["element"] = AnyCodable(snap.toDictionary())
                }
                if let prev = current.lastSnapshot, change != "appeared" {
                    eventData["previous"] = AnyCodable(prev.toDictionary())
                }

                let event = PepperEvent(event: "watch_update", data: eventData)
                PepperPlane.shared.broadcast(event)

                // Update stored snapshot
                WatchRegistry.shared.updateSnapshot(watch.id, snapshot: newSnapshot)
                logger.debug("Watch \(watch.id) change: \(change)")
            }
        }

        WatchRegistry.shared.setTimer(watch.id, timer: timer)
        timer.resume()
    }

    // MARK: - Snapshot

    private func takeSnapshot(target: WatchTarget) -> ElementSnapshot? {
        let bridge = PepperSwiftUIBridge.shared

        switch target {
        case .label(let text, let exact):
            let elements = bridge.collectAccessibilityElements()
            for elem in elements {
                guard let label = elem.label else { continue }
                let matches = exact ? label.pepperEquals(text) : label.pepperContains(text)
                if matches && elem.frame != .zero {
                    return ElementSnapshot(
                        label: elem.label,
                        type: elem.type,
                        center: CGPoint(x: elem.frame.midX, y: elem.frame.midY),
                        frame: elem.frame,
                        value: elem.value,
                        isInteractive: elem.isInteractive
                    )
                }
            }
            return nil

        case .point(let point):
            let elements = bridge.collectAccessibilityElements()
            // Find the element whose frame contains this point
            for elem in elements where elem.frame.contains(point) && elem.frame != .zero {
                return ElementSnapshot(
                    label: elem.label,
                    type: elem.type,
                    center: CGPoint(x: elem.frame.midX, y: elem.frame.midY),
                    frame: elem.frame,
                    value: elem.value,
                    isInteractive: elem.isInteractive
                )
            }
            return nil

        case .region(let rect):
            let elements = bridge.collectAccessibilityElements()
            let inRegion = elements.filter { $0.frame.intersects(rect) && $0.frame != .zero }
            guard !inRegion.isEmpty else { return nil }

            // Create a composite snapshot representing the region's contents
            let labels = inRegion.compactMap { $0.label }.joined(separator: "|")
            let count = inRegion.count
            return ElementSnapshot(
                label: labels.isEmpty ? nil : labels,
                type: "region(\(count))",
                center: CGPoint(x: rect.midX, y: rect.midY),
                frame: rect,
                value: "\(count) elements",
                isInteractive: false
            )
        }
    }

    // MARK: - Change Detection

    private func detectChange(previous: ElementSnapshot?, current: ElementSnapshot?) -> String? {
        switch (previous, current) {
        case (nil, nil):
            return nil
        case (nil, .some):
            return "appeared"
        case (.some, nil):
            return "disappeared"
        case (.some(let prev), .some(let cur)):
            // Check if label/value changed
            if prev.label != cur.label || prev.value != cur.value {
                return "value_changed"
            }
            // Check if moved significantly (>2pt)
            if abs(prev.center.x - cur.center.x) > 2 || abs(prev.center.y - cur.center.y) > 2 {
                return "moved"
            }
            // Check if interactivity changed
            if prev.isInteractive != cur.isInteractive {
                return "trait_changed"
            }
            return nil
        }
    }
}

// MARK: - Watch Data Types

enum WatchTarget: CustomStringConvertible {
    case label(text: String, exact: Bool)
    case point(CGPoint)
    case region(CGRect)

    var description: String {
        switch self {
        case .label(let text, let exact): return "label(\(text), exact=\(exact))"
        case .point(let p): return "point(\(Int(p.x)),\(Int(p.y)))"
        case .region(let r): return "region(\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height)))"
        }
    }
}

struct ElementSnapshot {
    let label: String?
    let type: String
    let center: CGPoint
    let frame: CGRect
    let value: String?
    let isInteractive: Bool

    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "type": AnyCodable(type),
            "center": AnyCodable([AnyCodable(Int(center.x)), AnyCodable(Int(center.y))]),
            "frame": AnyCodable([
                AnyCodable(Int(frame.origin.x)),
                AnyCodable(Int(frame.origin.y)),
                AnyCodable(Int(frame.size.width)),
                AnyCodable(Int(frame.size.height))
            ])
        ]
        if let label = label {
            dict["label"] = AnyCodable(label)
        }
        if let value = value {
            dict["value"] = AnyCodable(value)
        }
        return dict
    }
}

struct WatchEntry {
    let id: String
    let target: WatchTarget
    let intervalMs: Int
    let timeoutMs: Int
    var lastSnapshot: ElementSnapshot?
    let startTime: Date
}

// MARK: - Watch Registry (singleton)

/// Thread-safe registry for active watches.
final class WatchRegistry {
    static let shared = WatchRegistry()

    private let queue = DispatchQueue(label: "com.pepper.control.watch", attributes: .concurrent)
    private var watches: [String: WatchEntry] = [:]
    private var timers: [String: DispatchSourceTimer] = [:]
    private var counter: Int = 0

    private init() {}

    func nextID() -> String {
        queue.sync(flags: .barrier) {
            counter += 1
            return "w\(counter)"
        }
    }

    func register(_ watch: WatchEntry) {
        queue.async(flags: .barrier) {
            self.watches[watch.id] = watch
        }
    }

    func get(_ id: String) -> WatchEntry? {
        queue.sync { watches[id] }
    }

    func remove(_ id: String) {
        queue.async(flags: .barrier) {
            self.watches.removeValue(forKey: id)
            if let timer = self.timers.removeValue(forKey: id) {
                timer.cancel()
            }
        }
    }

    func setTimer(_ id: String, timer: DispatchSourceTimer) {
        queue.async(flags: .barrier) {
            self.timers[id] = timer
        }
    }

    func updateSnapshot(_ id: String, snapshot: ElementSnapshot?) {
        queue.async(flags: .barrier) {
            self.watches[id]?.lastSnapshot = snapshot
        }
    }

    /// All active watch IDs.
    var activeIDs: [String] {
        queue.sync { Array(watches.keys).sorted() }
    }

    /// Remove all watches and cancel all timers.
    func removeAll() {
        queue.async(flags: .barrier) {
            for timer in self.timers.values {
                timer.cancel()
            }
            self.timers.removeAll()
            self.watches.removeAll()
        }
    }
}

