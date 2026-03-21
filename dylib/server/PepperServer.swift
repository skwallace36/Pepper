import Foundation
import Network

/// Lightweight WebSocket server using Network.framework.
/// Accepts connections, parses JSON commands, routes to dispatcher,
/// and supports broadcasting events to all connected clients.
final class PepperServer {

    let port: UInt16
    let dispatcher: PepperDispatcher
    let connectionManager = PepperConnectionManager()

    /// NWListener for accepting incoming WebSocket connections.
    private var listener: NWListener?

    /// Serial queue for listener and connection handling.
    private let serverQueue = DispatchQueue(label: "com.pepper.control.server", qos: .userInitiated)

    /// JSON decoder/encoder for command protocol.
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Counter for generating unique connection IDs.
    private var nextConnectionID: Int = 0

    /// Fallback timeout when no handler-specific timeout is defined.
    private let defaultTimeoutInterval: TimeInterval = 10.0

    /// Rate limit: max messages per connection within the window.
    private static let rateLimitMaxMessages = 60
    /// Rate limit window in seconds (60 messages per 10 seconds).
    private static let rateLimitWindow: TimeInterval = 10.0

    init(port: UInt16, dispatcher: PepperDispatcher) {
        self.port = port
        self.dispatcher = dispatcher
        registerServerHandlers()
    }

    /// Register handlers that need access to the server (e.g. subscribe/unsubscribe).
    private func registerServerHandlers() {
        dispatcher.register(SubscribeHandler(connectionManager: connectionManager))
        dispatcher.register(UnsubscribeHandler(connectionManager: connectionManager))
        // Status command — report server and connection info
        dispatcher.register("status") { [weak self] cmd in
            guard let self = self else {
                return .error(id: cmd.id, message: "Server not available")
            }
            return .ok(id: cmd.id, data: [
                "connections": AnyCodable(self.connectionManager.connectionCount),
                "connectionDetails": AnyCodable(self.connectionManager.statusReport()),
                "port": AnyCodable(Int(self.port))
            ])
        }
    }

    // MARK: - Server Lifecycle

    func start() {
        // Configure WebSocket protocol options
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            pepperLog.error("Failed to create listener: \(error)", category: .server)
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: serverQueue)
        connectionManager.startCleanupTimer()
        pepperLog.info("Server starting on port \(port)", category: .server)
    }

    func stop() {
        connectionManager.stopCleanupTimer()
        listener?.cancel()
        listener = nil
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

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            pepperLog.info("Server ready on port \(port)", category: .server)
        case .failed(let error):
            pepperLog.error("Server failed: \(error)", category: .server)
            // Attempt restart after a short delay
            serverQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.listener?.cancel()
                self?.start()
            }
        case .cancelled:
            pepperLog.info("Server cancelled", category: .server)
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let connectionID = generateConnectionID()
        pepperLog.info("New connection: \(connectionID)", category: .server)

        // Register in connection manager with send callbacks for text and binary frames
        connectionManager.addConnection(
            id: connectionID,
            send: { [weak connection] data in
                Self.sendData(data, on: connection)
            },
            sendBinary: { [weak connection] data in
                Self.sendBinaryData(data, on: connection)
            }
        )

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, id: connectionID, connection: connection)
        }

        connection.start(queue: serverQueue)
        receiveMessage(on: connection, connectionID: connectionID)
    }

    private func handleConnectionState(_ state: NWConnection.State, id: String, connection: NWConnection) {
        switch state {
        case .ready:
            pepperLog.debug("Connection \(id) ready", category: .server)
        case .waiting(let error):
            pepperLog.debug("Connection \(id) waiting: \(error)", category: .server)
        case .failed(let error):
            pepperLog.warning("Connection \(id) failed: \(error)", category: .server)
            cleanupConnection(id: id, connection: connection)
        case .cancelled:
            pepperLog.debug("Connection \(id) cancelled", category: .server)
            connectionManager.removeConnection(id: id)
        default:
            break
        }
    }

    /// Centralized connection cleanup: removes from manager and cancels the NWConnection.
    private func cleanupConnection(id: String, connection: NWConnection) {
        connectionManager.removeConnection(id: id)
        connection.cancel()
    }

    // MARK: - Message Receive Loop

    private func receiveMessage(on connection: NWConnection, connectionID: String) {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                pepperLog.warning("Receive error on \(connectionID): \(error)", category: .server)
                self.cleanupConnection(id: connectionID, connection: connection)
                return
            }

            // Check if the connection is still tracked (may have been removed during cleanup)
            guard self.connectionManager.connection(for: connectionID) != nil else {
                pepperLog.debug("Receive loop ending for removed connection \(connectionID)", category: .server)
                return
            }

            // Check if this is a WebSocket text message
            if let content = content, !content.isEmpty,
               let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {

                switch metadata.opcode {
                case .text:
                    self.handleTextMessage(content, connectionID: connectionID, connection: connection)
                case .binary:
                    // Binary frames not supported; ignore
                    pepperLog.debug("Ignoring binary frame from \(connectionID)", category: .server)
                case .close:
                    pepperLog.debug("Close frame from \(connectionID)", category: .server)
                    self.cleanupConnection(id: connectionID, connection: connection)
                    return
                default:
                    break
                }
            }

            // Continue receiving
            self.receiveMessage(on: connection, connectionID: connectionID)
        }
    }

    // MARK: - Command Processing

    private func handleTextMessage(_ data: Data, connectionID: String, connection: NWConnection) {
        connectionManager.touchActivity(for: connectionID)

        // Guard against messages from already-disconnected clients
        guard connectionManager.connection(for: connectionID) != nil else {
            pepperLog.debug("Ignoring message from disconnected client \(connectionID)", category: .server)
            return
        }

        // Rate limiting
        if !connectionManager.checkRateLimit(for: connectionID, maxMessages: Self.rateLimitMaxMessages, window: Self.rateLimitWindow) {
            pepperLog.warning("Rate limit exceeded for \(connectionID)", category: .server)
            let errorResponse = PepperResponse.error(id: "unknown", message: "Rate limit exceeded. Max \(Self.rateLimitMaxMessages) messages per \(Int(Self.rateLimitWindow))s.")
            sendResponse(errorResponse, to: connectionID)
            return
        }

        do {
            var command = try decoder.decode(PepperCommand.self, from: data)
            pepperLog.debug("Received command '\(command.cmd)' id=\(command.id)", category: .commands, commandID: command.id)

            // Inject connection ID so handlers can access it (e.g. subscribe/unsubscribe)
            var params = command.params ?? [:]
            params["_connectionId"] = AnyCodable(connectionID)
            command = PepperCommand(id: command.id, cmd: command.cmd, params: params)

            dispatchWithTimeout(command, connectionID: connectionID)
        } catch {
            pepperLog.warning("Invalid JSON from \(connectionID): \(error)", category: .commands)
            // Send error response with a synthetic ID
            let errorResponse = PepperResponse.error(id: "unknown", message: "Invalid JSON: \(error.localizedDescription)")
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
            pepperLog.warning("Command '\(command.cmd)' id=\(command.id) timed out after \(timeoutInterval)s", category: .commands, commandID: command.id)
            let timeoutResponse = PepperResponse.error(id: command.id, message: "Command timed out after \(timeoutInterval) seconds")
            self?.sendResponse(timeoutResponse, to: connectionID)
        }

        // Dispatch the command — handler runs on main thread
        dispatcher.dispatch(command) { [weak self] response in
            guard !responded.setIfUnset() else {
                pepperLog.debug("Dropping late response for '\(command.cmd)' id=\(command.id) (already timed out)", category: .commands, commandID: command.id)
                return
            }
            self?.sendResponse(response, to: connectionID)
            pepperLog.debug("Responded to '\(command.cmd)' with \(response.status.rawValue)", category: .commands, commandID: command.id)
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

        guard let data = try? encoder.encode(response) else { return }
        connectionManager.send(data: data, to: connectionID)
    }

    /// Send raw data on a connection as a WebSocket text frame.
    /// Silently handles broken connections — will not crash if the connection is gone.
    private static func sendData(_ data: Data, on connection: NWConnection?) {
        guard let connection = connection else { return }

        // Don't attempt to send on a connection that is already cancelled or failed
        guard connection.state == .ready else {
            pepperLog.debug("Skipping send on non-ready connection (state: \(connection.state))", category: .server)
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "textFrame",
            metadata: [metadata]
        )

        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error = error {
                    pepperLog.warning("Send error: \(error)", category: .server)
                }
            }
        )
    }

    /// Send raw data on a connection as a WebSocket binary frame.
    private static func sendBinaryData(_ data: Data, on connection: NWConnection?) {
        guard let connection = connection else { return }
        guard connection.state == .ready else {
            pepperLog.debug("Skipping binary send on non-ready connection (state: \(connection.state))", category: .server)
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "binaryFrame",
            metadata: [metadata]
        )

        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error = error {
                    pepperLog.warning("Binary send error: \(error)", category: .server)
                }
            }
        )
    }

    // MARK: - Helpers

    private func generateConnectionID() -> String {
        nextConnectionID += 1
        return "conn-\(nextConnectionID)"
    }
}

// MARK: - LockedFlag

/// Thread-safe one-shot flag. Used to ensure only one of two competing
/// completions (e.g. timeout vs handler response) can fire.
final class LockedFlag {
    private var _set = false
    private let lock = NSLock()

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

