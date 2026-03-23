import Foundation
import Network

/// Concrete `WebSocketTransport` backed by Network.framework's NWListener.
///
/// Wraps all NWListener and NWConnection lifecycle management.
/// PepperServer consumes this through the `WebSocketTransport` protocol.
final class NWListenerTransport: WebSocketTransport {

    let port: UInt16
    weak var delegate: TransportDelegate?

    /// The underlying Network.framework listener.
    private var listener: NWListener?

    /// Serial queue for all listener and connection operations.
    private let queue = DispatchQueue(label: "com.pepper.transport.nw", qos: .userInitiated)

    /// Counter for generating unique connection IDs.
    private var nextConnectionID: Int = 0

    /// Active connections keyed by connection ID, for broadcast and cleanup.
    private var connections: [String: NWTransportConnection] = [:]

    init(port: UInt16) {
        self.port = port
    }

    // MARK: - WebSocketTransport

    func start() {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            // swiftlint:disable:next force_unwrapping
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            pepperLog.error("Failed to create listener: \(error)", category: .server)
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        listener?.newConnectionHandler = { [weak self] nwConnection in
            self?.handleNewConnection(nwConnection)
        }

        listener?.start(queue: queue)
        pepperLog.info("Transport starting on port \(port)", category: .server)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let snapshot = connections
        connections.removeAll()
        for (_, conn) in snapshot {
            conn.nwConnection.cancel()
        }
        pepperLog.info("Transport stopped", category: .server)
    }

    func broadcast(_ data: Data) {
        for (_, conn) in connections {
            conn.send(data)
        }
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            pepperLog.info("Transport ready on port \(port)", category: .server)
        case .failed(let error):
            pepperLog.error("Transport failed: \(error)", category: .server)
            // Attempt restart after a short delay
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.listener?.cancel()
                self?.start()
            }
        case .cancelled:
            pepperLog.info("Transport cancelled", category: .server)
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let id = generateConnectionID()
        let conn = NWTransportConnection(connectionId: id, nwConnection: nwConnection)
        connections[id] = conn

        pepperLog.info("New connection: \(id)", category: .server)
        delegate?.transportDidAccept(conn)

        nwConnection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, conn: conn)
        }

        nwConnection.start(queue: queue)
        receiveMessage(on: conn)
    }

    private func handleConnectionState(_ state: NWConnection.State, conn: NWTransportConnection) {
        switch state {
        case .ready:
            pepperLog.debug("Connection \(conn.connectionId) ready", category: .server)
        case .waiting(let error):
            pepperLog.debug("Connection \(conn.connectionId) waiting: \(error)", category: .server)
        case .failed(let error):
            pepperLog.warning("Connection \(conn.connectionId) failed: \(error)", category: .server)
            cleanup(conn)
        case .cancelled:
            pepperLog.debug("Connection \(conn.connectionId) cancelled", category: .server)
            connections.removeValue(forKey: conn.connectionId)
            delegate?.transportDidClose(conn)
        default:
            break
        }
    }

    private func cleanup(_ conn: NWTransportConnection) {
        connections.removeValue(forKey: conn.connectionId)
        delegate?.transportDidClose(conn)
        conn.nwConnection.cancel()
    }

    // MARK: - Message Receive Loop

    private func receiveMessage(on conn: NWTransportConnection) {
        conn.nwConnection.receiveMessage { [weak self] content, context, _, error in
            guard let self = self else { return }

            if let error = error {
                pepperLog.warning("Receive error on \(conn.connectionId): \(error)", category: .server)
                self.cleanup(conn)
                return
            }

            // Connection may have been removed during cleanup
            guard self.connections[conn.connectionId] != nil else {
                pepperLog.debug("Receive loop ending for removed connection \(conn.connectionId)", category: .server)
                return
            }

            if let content = content, !content.isEmpty,
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
            {

                switch metadata.opcode {
                case .text:
                    self.delegate?.transportDidReceive(conn, data: content)
                case .binary:
                    pepperLog.debug("Ignoring binary frame from \(conn.connectionId)", category: .server)
                case .close:
                    pepperLog.debug("Close frame from \(conn.connectionId)", category: .server)
                    self.cleanup(conn)
                    return
                default:
                    break
                }
            }

            self.receiveMessage(on: conn)
        }
    }

    // MARK: - Helpers

    private func generateConnectionID() -> String {
        nextConnectionID += 1
        return "conn-\(nextConnectionID)"
    }
}

// MARK: - NWTransportConnection

/// Concrete `TransportConnection` wrapping an NWConnection.
final class NWTransportConnection: TransportConnection {

    let connectionId: String

    /// The underlying NWConnection (internal so the transport can manage lifecycle).
    let nwConnection: NWConnection

    init(connectionId: String, nwConnection: NWConnection) {
        self.connectionId = connectionId
        self.nwConnection = nwConnection
    }

    func send(_ data: Data) {
        guard nwConnection.state == .ready else {
            pepperLog.debug("Skipping send on non-ready connection (state: \(nwConnection.state))", category: .server)
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "textFrame",
            metadata: [metadata]
        )

        nwConnection.send(
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

    func sendBinary(_ data: Data) {
        guard nwConnection.state == .ready else {
            pepperLog.debug(
                "Skipping binary send on non-ready connection (state: \(nwConnection.state))", category: .server)
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "binaryFrame",
            metadata: [metadata]
        )

        nwConnection.send(
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

    func close() {
        nwConnection.cancel()
    }
}
