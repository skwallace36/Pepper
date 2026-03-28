import Foundation

/// Advertises the Pepper WebSocket server via Bonjour (mDNS/DNS-SD)
/// so that hosts on the local network can discover it without knowing the port.
///
/// Service type: `_pepper._tcp.`
/// TXT record includes the bundle ID for filtering when multiple apps run Pepper.
final class PepperBonjourAdvertiser: NSObject, NetServiceDelegate {

    /// Bonjour service type used for discovery.
    static let serviceType = "_pepper._tcp."

    private var netService: NetService?
    private let port: UInt16
    private let serviceName: String

    /// Optional key-value pairs published in the TXT record.
    private let txtData: [String: String]

    /// - Parameters:
    ///   - port: The WebSocket port to advertise.
    ///   - serviceName: Human-readable name (defaults to the app's bundle ID).
    ///   - txtData: Extra metadata published in the DNS-SD TXT record.
    init(port: UInt16, serviceName: String? = nil, txtData: [String: String] = [:]) {
        self.port = port
        let bundleID = Bundle.main.bundleIdentifier ?? "com.pepper.unknown"
        self.serviceName = serviceName ?? "Pepper-\(bundleID)"
        var txt = txtData
        txt["bundleID"] = bundleID
        self.txtData = txt
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard netService == nil else { return }

        let service = NetService(
            domain: "",  // default domain (local.)
            type: Self.serviceType,
            name: serviceName,
            port: Int32(port)
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: txtData.mapValues { Data($0.utf8) }))
        service.publish()
        netService = service

        pepperLog.info("Bonjour advertising \(Self.serviceType) on port \(port) as '\(serviceName)'", category: .server)
    }

    func stop() {
        netService?.stop()
        netService = nil
        pepperLog.info("Bonjour advertisement stopped", category: .server)
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        pepperLog.info("Bonjour service published: \(sender.name) on port \(port)", category: .server)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        pepperLog.warning("Bonjour publish failed: \(errorDict)", category: .server)
    }

    func netServiceDidStop(_ sender: NetService) {
        pepperLog.debug("Bonjour service stopped: \(sender.name)", category: .server)
    }
}
