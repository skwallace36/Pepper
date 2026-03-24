import Foundation

/// Lightweight WebSocket server that accepts connections, parses JSON commands,
/// routes to dispatcher, and supports broadcasting events to all connected clients.
///
/// Transport-agnostic: receives connection lifecycle events through `TransportDelegate`.
/// The concrete transport (e.g. `NWListenerTransport`) is injected at init.
final class PepperServer {

    let dispatcher: PepperDispatcher
    let connectionManager = PepperConnectionManager()

    /// The pluggable WebSocket transport layer.
    private var transport: WebSocketTransport

    /// Serial queue for command processing and timeout scheduling.
    private let serverQueue = DispatchQueue(label: "com.pepper.control.server", qos: .userInitiated)

    /// JSON decoder/encoder for command protocol.
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Fallback timeout when no handler-specific timeout is defined.
    private let defaultTimeoutInterval: TimeInterval = 10.0

    /// Rate limit: max messages per connection within the window.
    private static let rateLimitMaxMessages = 60
    /// Rate limit window in seconds (60 messages per 10 seconds).
    private static let rateLimitWindow: TimeInterval = 10.0

    init(transport: WebSocketTransport, dispatcher: PepperDispatcher) {
        self.transport = transport
        self.dispatcher = dispatcher
        self.transport.delegate = self
        registerServerHandlers()
    }

    /// The port the underlying transport is listening on.
    var port: UInt16 { transport.port }

    /// Register handlers that need access to the server (e.g. subscribe/unsubscribe).
    private func registerServerHandlers() {
        dispatcher.register(SubscribeHandler(connectionManager: connectionManager))
        dispatcher.register(UnsubscribeHandler(connectionManager: connectionManager))
        // Status command — report server and connection info
        dispatcher.register("status") { [weak self] cmd in
            guard let self = self else {
                return .error(id: cmd.id, message: "Server not available")
            }
            return .ok(
                id: cmd.id,
                data: [
                    "connections": AnyCodable(self.connectionManager.connectionCount),
                    "connectionDetails": AnyCodable(self.connectionManager.statusReport()),
                    "port": AnyCodable(Int(self.port)),
                ])
        }
    }

    // MARK: - Server Lifecycle

    func start() {
        transport.start()
        connectionManager.startCleanupTimer()
        pepperLog.info("Server starting on port \(port)", category: .server)
    }

    func stop() {
        connectionManager.stopCleanupTimer()
        transport.stop()
        // Remove all tracked connections
        for id in connectionManager.connectionIDs {
            connectionManager.removeConnection(id: id)
        }
        pepperLog.info("Server stopped", category: .server)
    }

    /// Broadcast an event to all connected clients (or those subscribed to the event type).
    func broadcast(_ event: PepperEvent) {
        connectionManager.broadcast(event: event)
    }

    // MARK: - Command Processing

    private func handleTextMessage(_ data: Data, connectionID: String) {
        connectionManager.touchActivity(for: connectionID)

        // Guard against messages from already-disconnected clients
        guard connectionManager.connection(for: connectionID) != nil else {
            pepperLog.debug("Ignoring message from disconnected client \(connectionID)", category: .server)
            return
        }

        // Rate limiting
        if !connectionManager.checkRateLimit(
            for: connectionID, maxMessages: Self.rateLimitMaxMessages, window: Self.rateLimitWindow)
        {
            pepperLog.warning("Rate limit exceeded for \(connectionID)", category: .server)
            let errorResponse = PepperResponse.error(
                id: "unknown",
                message:
                    "Rate limit exceeded. Max \(Self.rateLimitMaxMessages) messages per \(Int(Self.rateLimitWindow))s.")
            sendResponse(errorResponse, to: connectionID)
            return
        }

        do {
            var command = try decoder.decode(PepperCommand.self, from: data)
            pepperLog.debug(
                "Received command '\(command.cmd)' id=\(command.id)", category: .commands, commandID: command.id)

            // Inject connection ID so handlers can access it (e.g. subscribe/unsubscribe)
            var params = command.params ?? [:]
            params["_connectionId"] = AnyCodable(connectionID)
            command = PepperCommand(id: command.id, cmd: command.cmd, params: params)

            dispatchWithTimeout(command, connectionID: connectionID)
        } catch {
            pepperLog.warning("Invalid JSON from \(connectionID): \(error)", category: .commands)
            // Send error response with a synthetic ID
            let errorResponse = PepperResponse.error(
                id: "unknown", message: "Invalid JSON: \(error.localizedDescription)")
            sendResponse(errorResponse, to: connectionID)
        }
    }

    /// Dispatch a command with a timeout guard. If the handler does not respond
    /// within `commandTimeoutInterval`, a timeout error is returned to the client.
    private func dispatchWithTimeout(_ command: PepperCommand, connectionID: String) {
        /// Flag to ensure only one response (either real or timeout) is sent.
        let responded = LockedFlag()

        // Use per-handler timeout (or default fallback)
        let timeoutInterval = dispatcher.timeout(for: command.cmd)

        // Schedule a timeout on the server queue
        serverQueue.asyncAfter(deadline: .now() + timeoutInterval) { [weak self] in
            guard !responded.setIfUnset() else { return }
            pepperLog.warning(
                "Command '\(command.cmd)' id=\(command.id) timed out after \(timeoutInterval)s", category: .commands,
                commandID: command.id)
            let timeoutResponse = PepperResponse.error(
                id: command.id, message: "Command timed out after \(timeoutInterval) seconds")
            self?.sendResponse(timeoutResponse, to: connectionID)
        }

        // Dispatch the command — handler runs on main thread.
        // Pass `responded` as cancellation flag so stale handler blocks from
        // timed-out commands are skipped, preventing cascading main-thread blockage.
        dispatcher.dispatch(command, cancelled: responded) { [weak self] response in
            guard !responded.setIfUnset() else {
                pepperLog.debug(
                    "Dropping late response for '\(command.cmd)' id=\(command.id) (already timed out)",
                    category: .commands, commandID: command.id)
                return
            }
            self?.sendResponse(response, to: connectionID)
            pepperLog.debug(
                "Responded to '\(command.cmd)' with \(response.status.rawValue)", category: .commands,
                commandID: command.id)
        }
    }

    // MARK: - Sending

    private func sendResponse(_ response: PepperResponse, to connectionID: String) {
        // Check for binary payload attached by a handler (e.g. screenshot with binary mode).
        // Binary frame format: [4-byte big-endian header length][JSON header][raw binary payload]
        if let binaryPayload = PepperResponse.takeBinaryPayload(for: response.id) {
            guard let headerData = try? encoder.encode(response) else { return }
            var headerLen = UInt32(headerData.count).bigEndian
            var frame = Data(bytes: &headerLen, count: 4)
            frame.append(headerData)
            frame.append(binaryPayload)
            connectionManager.sendBinary(data: frame, to: connectionID)
            return
        }

        guard let data = try? encoder.encode(response) else {
            pepperLog.warning(
                "Failed to encode response id=\(response.id) status=\(response.status.rawValue) — "
                + "response dropped (possible non-finite float or unencodable value)",
                category: .server)
            return
        }
        connectionManager.send(data: data, to: connectionID)
    }
}

// MARK: - TransportDelegate

extension PepperServer: TransportDelegate {
    func transportDidAccept(_ connection: TransportConnection) {
        let id = connection.connectionId
        pepperLog.info("New connection: \(id)", category: .server)

        // Register in connection manager with send callbacks routed to the transport connection
        connectionManager.addConnection(
            id: id,
            send: { [weak connection] data in
                connection?.send(data)
            },
            sendBinary: { [weak connection] data in
                connection?.sendBinary(data)
            }
        )
    }

    func transportDidClose(_ connection: TransportConnection) {
        let id = connection.connectionId
        connectionManager.removeConnection(id: id)
    }

    func transportDidReceive(_ connection: TransportConnection, data: Data) {
        handleTextMessage(data, connectionID: connection.connectionId)
    }
}

// MARK: - LockedFlag

/// Thread-safe one-shot flag. Used to ensure only one of two competing
/// completions (e.g. timeout vs handler response) can fire.
final class LockedFlag {
    private var _set = false
    private let lock = NSLock()

    /// Check if the flag has been set (non-mutating).
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _set
    }

    /// Atomically set the flag if it hasn't been set yet.
    /// Returns `true` if the flag was already set (meaning this call lost the race).
    @discardableResult
    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _set { return true }
        _set = true
        return false
    }
}
