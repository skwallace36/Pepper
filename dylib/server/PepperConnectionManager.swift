import Foundation

// MARK: - Connection Info

/// Metadata for a single WebSocket connection.
final class PepperConnectionInfo {
    /// Unique identifier for this connection.
    let id: String

    /// When the connection was established.
    let connectedAt: Date

    /// Last time a message was received from this client.
    private(set) var lastActivity: Date

    /// Event types this connection is subscribed to.
    private(set) var subscriptions: Set<String>

    /// Callback to send a text frame to this connection.
    let send: (Data) -> Void

    /// Callback to send a binary frame to this connection.
    let sendBinary: (Data) -> Void

    /// Callback to close the underlying transport connection.
    let close: () -> Void

    /// Timestamps of recent messages for rate limiting (sliding window).
    private var recentMessages: [Date] = []

    init(id: String, send: @escaping (Data) -> Void, sendBinary: @escaping (Data) -> Void, close: @escaping () -> Void) {
        self.id = id
        self.connectedAt = Date()
        self.lastActivity = Date()
        self.subscriptions = []
        self.send = send
        self.sendBinary = sendBinary
        self.close = close
    }

    func touchActivity() {
        lastActivity = Date()
    }

    /// Record a message and check if the connection is exceeding the rate limit.
    /// - Parameters:
    ///   - maxMessages: Maximum messages allowed within the window.
    ///   - window: Time window in seconds.
    /// - Returns: `true` if the message is allowed, `false` if rate limited.
    func checkRateLimit(maxMessages: Int, window: TimeInterval) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-window)
        recentMessages.removeAll { $0 < cutoff }
        if recentMessages.count >= maxMessages {
            return false
        }
        recentMessages.append(now)
        return true
    }

    func subscribe(to eventType: String) {
        subscriptions.insert(eventType)
    }

    func unsubscribe(from eventType: String) {
        subscriptions.remove(eventType)
    }

    /// Whether this connection receives events of the given type.
    /// A connection with no subscriptions receives all events (wildcard).
    func isSubscribed(to eventType: String) -> Bool {
        subscriptions.isEmpty || subscriptions.contains(eventType)
    }
}

// MARK: - Connection Manager

/// Thread-safe manager for active WebSocket connections.
/// Tracks connections, handles send/broadcast, and supports event subscriptions.
final class PepperConnectionManager {

    /// Serial queue for thread-safe access to the connections dictionary.
    private let queue = DispatchQueue(label: "com.pepper.control.connections", qos: .userInitiated)

    /// Active connections keyed by connection ID.
    private var connections: [String: PepperConnectionInfo] = [:]

    /// JSON encoder shared across broadcasts.
    private let encoder = JSONEncoder()

    /// Maximum number of simultaneous connections. When exceeded, the oldest
    /// idle connection is evicted to make room.
    private static let maxConnections = 20

    // MARK: - Connection Lifecycle

    /// Register a new connection.
    @discardableResult
    func addConnection(id: String, send: @escaping (Data) -> Void, sendBinary: @escaping (Data) -> Void, close: @escaping () -> Void)
        -> PepperConnectionInfo
    {
        let info = PepperConnectionInfo(id: id, send: send, sendBinary: sendBinary, close: close)
        let evicted: PepperConnectionInfo? = queue.sync {
            // Evict oldest idle connection if at capacity
            if connections.count >= Self.maxConnections,
               let oldest = connections.values.min(by: { $0.lastActivity < $1.lastActivity })
            {
                connections.removeValue(forKey: oldest.id)
                return oldest
            }
            connections[id] = info
            return nil
        }
        if let evicted = evicted {
            pepperLog.info("Evicted oldest connection \(evicted.id) (cap=\(Self.maxConnections))", category: .server)
            evicted.close()
            // Insert after eviction (outside the sync that found the victim)
            queue.sync { connections[id] = info }
        }
        pepperLog.info("Connection added: \(id) (total: \(connectionCount))", category: .server)
        return info
    }

    /// Remove a connection by ID.
    func removeConnection(id: String) {
        queue.sync {
            _ = connections.removeValue(forKey: id)
        }
        pepperLog.info("Connection removed: \(id)", category: .server)
    }

    /// Look up a connection by ID.
    func connection(for id: String) -> PepperConnectionInfo? {
        queue.sync { connections[id] }
    }

    /// Record activity on a connection (e.g. when a message is received).
    func touchActivity(for id: String) {
        queue.sync {
            connections[id]?.touchActivity()
        }
    }

    // MARK: - Subscriptions

    /// Subscribe a connection to an event type.
    func subscribe(connectionID: String, to eventType: String) {
        queue.sync {
            connections[connectionID]?.subscribe(to: eventType)
        }
    }

    /// Unsubscribe a connection from an event type.
    func unsubscribe(connectionID: String, from eventType: String) {
        queue.sync {
            connections[connectionID]?.unsubscribe(from: eventType)
        }
    }

    // MARK: - Sending

    /// Send data to a specific connection.
    /// Silently drops the message if the connection no longer exists.
    func send(data: Data, to connectionID: String) {
        let info = queue.sync { connections[connectionID] }
        guard let info = info else {
            pepperLog.debug("Dropping send to unknown connection \(connectionID)", category: .server)
            return
        }
        info.send(data)
    }

    /// Send an encodable value to a specific connection.
    func send<T: Encodable>(_ value: T, to connectionID: String) {
        guard let data = try? encoder.encode(value) else {
            pepperLog.warning(
                "Failed to encode \(T.self) for send to \(connectionID) — message dropped", category: .server)
            return
        }
        send(data: data, to: connectionID)
    }

    /// Send binary data to a specific connection as a binary WebSocket frame.
    /// Silently drops the message if the connection no longer exists.
    func sendBinary(data: Data, to connectionID: String) {
        let info = queue.sync { connections[connectionID] }
        guard let info = info else {
            pepperLog.debug("Dropping binary send to unknown connection \(connectionID)", category: .server)
            return
        }
        info.sendBinary(data)
    }

    /// Broadcast data to all connected clients.
    func broadcast(data: Data) {
        let snapshot = queue.sync { Array(connections.values) }
        for info in snapshot {
            info.send(data)
        }
    }

    /// Broadcast an encodable value to all connected clients.
    func broadcast<T: Encodable>(_ value: T) {
        guard let data = try? encoder.encode(value) else {
            pepperLog.warning("Failed to encode \(T.self) for broadcast — message dropped", category: .server)
            return
        }
        broadcast(data: data)
    }

    /// Broadcast an event to connections subscribed to its event type.
    func broadcast(event: PepperEvent) {
        guard let data = try? encoder.encode(event) else {
            pepperLog.warning(
                "Failed to encode event '\(event.event)' for broadcast — event dropped", category: .server)
            return
        }
        let snapshot = queue.sync { Array(connections.values) }
        for info in snapshot where info.isSubscribed(to: event.event) {
            info.send(data)
        }
    }

    // MARK: - Status

    /// Number of currently active connections.
    var connectionCount: Int {
        queue.sync { connections.count }
    }

    /// IDs of all active connections.
    var connectionIDs: [String] {
        queue.sync { Array(connections.keys) }
    }

    /// Summary of all connections for status reporting.
    func statusReport() -> [[String: AnyCodable]] {
        let snapshot = queue.sync { Array(connections.values) }
        return snapshot.map { info in
            [
                "id": AnyCodable(info.id),
                "connectedAt": AnyCodable(ISO8601DateFormatter().string(from: info.connectedAt)),
                "lastActivity": AnyCodable(ISO8601DateFormatter().string(from: info.lastActivity)),
                "subscriptions": AnyCodable(info.subscriptions.map { AnyCodable($0) }),
            ]
        }
    }

    /// Remove connections that have been inactive longer than the given interval.
    /// Closes the underlying transport connection so both layers are cleaned up.
    func cleanupStale(olderThan interval: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-interval)
        let stale: [PepperConnectionInfo] = queue.sync {
            connections.filter { $0.value.lastActivity < cutoff }.map { $0.value }
        }
        for info in stale {
            removeConnection(id: info.id)
            info.close()
        }
        if !stale.isEmpty {
            pepperLog.info("Cleaned up \(stale.count) stale connection(s)", category: .server)
        }
    }

    // MARK: - Periodic Stale Connection Cleanup

    /// Timer for periodic stale connection cleanup.
    private var cleanupTimer: DispatchSourceTimer?

    /// How long a connection can be idle before being cleaned up (5 minutes).
    private static let staleTimeout: TimeInterval = 300

    /// How often to check for stale connections (60 seconds).
    private static let cleanupInterval: TimeInterval = 60

    /// Start a periodic timer that removes stale connections.
    func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.cleanupInterval, repeating: Self.cleanupInterval)
        timer.setEventHandler { [weak self] in
            self?.cleanupStale(olderThan: Self.staleTimeout)
        }
        timer.resume()
        cleanupTimer = timer
    }

    /// Stop the periodic cleanup timer.
    func stopCleanupTimer() {
        cleanupTimer?.cancel()
        cleanupTimer = nil
    }

    // MARK: - Rate Limiting

    /// Check rate limit for a connection.
    /// - Returns: `true` if the message is allowed.
    func checkRateLimit(for connectionID: String, maxMessages: Int, window: TimeInterval) -> Bool {
        queue.sync {
            connections[connectionID]?.checkRateLimit(maxMessages: maxMessages, window: window) ?? false
        }
    }
}
