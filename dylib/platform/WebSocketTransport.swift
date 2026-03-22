import Foundation

/// Opaque handle to a single client connection.
///
/// Platform implementations wrap their native connection type
/// (e.g. NWConnection on iOS) behind this interface.
protocol TransportConnection: AnyObject {
    /// Unique identifier for this connection.
    var connectionId: String { get }

    /// Send a UTF-8 text frame to this client.
    func send(_ data: Data)

    /// Send a binary frame to this client (e.g. screenshots).
    func sendBinary(_ data: Data)

    /// Close this connection.
    func close()
}

/// Callbacks from the transport layer to the server core.
protocol TransportDelegate: AnyObject {
    /// A new client connected.
    func transportDidAccept(_ connection: TransportConnection)

    /// A client disconnected.
    func transportDidClose(_ connection: TransportConnection)

    /// A text message was received from a client.
    func transportDidReceive(_ connection: TransportConnection, data: Data)
}

/// Abstracts the WebSocket listener/server implementation.
///
/// iOS implementation wraps NWListener (Network.framework).
/// Android could use OkHttp WebSocket server or Ktor.
protocol WebSocketTransport {
    /// The port this transport is listening on.
    var port: UInt16 { get }

    /// Delegate that receives connection lifecycle and message events.
    var delegate: TransportDelegate? { get set }

    /// Start listening for incoming connections.
    func start()

    /// Stop listening and close all connections.
    func stop()

    /// Broadcast data to all active connections.
    func broadcast(_ data: Data)
}
