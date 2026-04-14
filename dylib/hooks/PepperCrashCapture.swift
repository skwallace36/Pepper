import Foundation
import MachO
import os

/// Captures uncaught ObjC exceptions and fatal signals (SIGABRT, SIGSEGV, SIGBUS)
/// with symbolicated stack traces. Crash reports persist to disk so they survive
/// process death and are available on next launch.
///
/// Uses the same dladdr() symbolication pattern as PepperHangDetector.
final class PepperCrashCapture {
    static let shared = PepperCrashCapture()

    private var logger: Logger { PepperLogger.logger(category: "crash-capture") }

    // MARK: - State

    private(set) var isInstalled = false

    /// In-memory crash events loaded from disk (newest first).
    private var crashEvents: [CrashEvent] = []
    private let lock = NSLock()

    /// Maximum crash reports retained on disk.
    private let maxCrashReports = 20

    /// Directory for persisted crash reports.
    private lazy var crashDir: URL = {
        let tmp = FileManager.default.temporaryDirectory
        let dir = tmp.appendingPathComponent("pepper-crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Previous ObjC exception handler (chained).
    fileprivate var previousExceptionHandler: NSUncaughtExceptionHandler?

    private init() {}

    // MARK: - Install

    func install() {
        guard !isInstalled else { return }
        isInstalled = true

        // Load any crash reports from previous runs
        loadPersistedCrashes()

        // Install ObjC uncaught exception handler
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(pepperExceptionHandler)

        // Install signal handlers for fatal signals
        installSignalHandlers()

        logger.info("Crash capture installed. \(self.crashEvents.count) previous crash(es) loaded.")
    }

    // MARK: - Query

    func getEvents(limit: Int = 10) -> [CrashEvent] {
        lock.lock()
        let events = Array(crashEvents.prefix(limit))
        lock.unlock()
        return events
    }

    func clearEvents() {
        lock.lock()
        crashEvents.removeAll()
        lock.unlock()

        // Remove persisted files
        if let files = try? FileManager.default.contentsOfDirectory(
            at: crashDir, includingPropertiesForKeys: nil)
        {
            for file in files where file.pathExtension == "json" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    var eventCount: Int {
        lock.lock()
        let count = crashEvents.count
        lock.unlock()
        return count
    }

    // MARK: - Signal Handlers

    /// Previous signal actions for chaining.
    private static var previousSIGABRT = sigaction()
    private static var previousSIGSEGV = sigaction()
    private static var previousSIGBUS = sigaction()
    private static var previousSIGTRAP = sigaction()

    private func installSignalHandlers() {
        installSignal(SIGABRT, previous: &PepperCrashCapture.previousSIGABRT)
        installSignal(SIGSEGV, previous: &PepperCrashCapture.previousSIGSEGV)
        installSignal(SIGBUS, previous: &PepperCrashCapture.previousSIGBUS)
        installSignal(SIGTRAP, previous: &PepperCrashCapture.previousSIGTRAP)
    }

    private func installSignal(_ sig: Int32, previous: inout sigaction) {
        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = pepperSignalHandler
        action.sa_flags = SA_SIGINFO
        sigemptyset(&action.sa_mask)
        sigaction(sig, &action, &previous)
    }

    // MARK: - Crash Recording (called from signal/exception context)

    /// Record a crash event and persist to disk. Process is dying — be fast.
    fileprivate func recordCrash(_ event: CrashEvent) {
        persistCrash(event)
        broadcastCrash(event)
    }

    private func persistCrash(_ event: CrashEvent) {
        let filename = "crash-\(event.id).json"
        let url = crashDir.appendingPathComponent(filename)
        guard let data = try? JSONEncoder().encode(event) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func broadcastCrash(_ event: CrashEvent) {
        let pepperEvent = PepperEvent(
            event: "crash",
            data: event.toDictionary()
        )
        PepperPlane.shared.broadcast(pepperEvent)
    }

    // MARK: - Persistence

    private func loadPersistedCrashes() {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: crashDir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        let jsonFiles =
            files
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let aDate =
                    (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                let bDate =
                    (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
                return aDate > bDate
            }

        lock.lock()
        for file in jsonFiles.prefix(maxCrashReports) {
            if let data = try? Data(contentsOf: file),
                let event = try? JSONDecoder().decode(CrashEvent.self, from: data)
            {
                crashEvents.append(event)
            }
        }
        lock.unlock()

        // Prune old files
        for file in jsonFiles.dropFirst(maxCrashReports) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Symbolication

    fileprivate static func symbolicate(_ address: UInt) -> StackFrame {
        var info = Dl_info()
        let found = dladdr(UnsafeRawPointer(bitPattern: address), &info)

        guard found != 0 else {
            return StackFrame(address: address, symbol: nil, image: nil, offset: 0)
        }

        let symbol = info.dli_sname.map { String(cString: $0) }
        let image = info.dli_fname.map { fname -> String in
            let path = String(cString: fname)
            return (path as NSString).lastPathComponent
        }
        let offset = address - UInt(bitPattern: info.dli_saddr)

        return StackFrame(address: address, symbol: symbol, image: image, offset: offset)
    }

    fileprivate static func symbolicateCallStack(_ addresses: [NSNumber]) -> [StackFrame] {
        addresses.map { symbolicate(UInt(truncating: $0)) }
    }
}

// MARK: - C-level Handlers

private func pepperExceptionHandler(_ exception: NSException) {
    let frames = PepperCrashCapture.symbolicateCallStack(exception.callStackReturnAddresses)

    let event = CrashEvent(
        id: UUID().uuidString,
        timestamp: Date(),
        type: .exception,
        name: exception.name.rawValue,
        reason: exception.reason ?? "Unknown reason",
        stack: frames,
        signal: nil,
        faultAddress: nil
    )

    PepperCrashCapture.shared.recordCrash(event)

    // Chain to previous handler
    if let previous = PepperCrashCapture.shared.previousExceptionHandler {
        previous(exception)
    }
}

private func pepperSignalHandler(
    _ signal: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _ context: UnsafeMutableRawPointer?
) {
    let signalName: String
    switch signal {
    case SIGABRT: signalName = "SIGABRT"
    case SIGSEGV: signalName = "SIGSEGV"
    case SIGBUS: signalName = "SIGBUS"
    case SIGTRAP: signalName = "SIGTRAP"
    default: signalName = "SIG\(signal)"
    }

    let faultAddress: UInt? = info.map { UInt(bitPattern: $0.pointee.si_addr) }

    // Walk current stack via backtrace()
    var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
    let frameCount = backtrace(&addresses, Int32(addresses.count))

    var frames: [StackFrame] = []
    for i in 0..<Int(frameCount) {
        if let addr = addresses[i] {
            frames.append(PepperCrashCapture.symbolicate(UInt(bitPattern: addr)))
        }
    }

    let event = CrashEvent(
        id: UUID().uuidString,
        timestamp: Date(),
        type: .signal,
        name: signalName,
        reason: "Fatal signal \(signalName) at \(faultAddress.map { String(format: "0x%lx", $0) } ?? "unknown")",
        stack: frames,
        signal: signal,
        faultAddress: faultAddress
    )

    PepperCrashCapture.shared.recordCrash(event)

    // Re-raise with default handler so OS crash reporter still runs
    var defaultAction = sigaction()
    defaultAction.__sigaction_u.__sa_handler = SIG_DFL
    sigemptyset(&defaultAction.sa_mask)
    sigaction(signal, &defaultAction, nil)
    raise(signal)
}

// MARK: - CrashEvent

struct CrashEvent: Codable {
    let id: String
    let timestamp: Date
    let type: CrashType
    let name: String
    let reason: String
    let stack: [CrashStackFrame]
    let signal: Int32?
    let faultAddress: UInt?

    enum CrashType: String, Codable {
        case exception
        case signal
    }

    /// Build from StackFrame array (converts to Codable CrashStackFrame).
    init(
        id: String, timestamp: Date, type: CrashType, name: String, reason: String,
        stack: [StackFrame], signal: Int32?, faultAddress: UInt?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.name = name
        self.reason = reason
        self.stack = stack.map { CrashStackFrame(from: $0) }
        self.signal = signal
        self.faultAddress = faultAddress
    }

    func toDictionary() -> [String: AnyCodable] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var dict: [String: AnyCodable] = [
            "id": AnyCodable(id),
            "timestamp": AnyCodable(formatter.string(from: timestamp)),
            "type": AnyCodable(type.rawValue),
            "name": AnyCodable(name),
            "reason": AnyCodable(reason),
            "stack_depth": AnyCodable(stack.count),
        ]

        if let signal = signal {
            dict["signal"] = AnyCodable(Int(signal))
        }
        if let faultAddress = faultAddress {
            dict["fault_address"] = AnyCodable(String(format: "0x%lx", faultAddress))
        }

        dict["stack"] = AnyCodable(stack.map { AnyCodable($0.toDictionary()) })

        let traceLines = stack.enumerated().map { i, frame in
            "\(i)  \(frame.description)"
        }
        dict["stack_trace"] = AnyCodable(traceLines.joined(separator: "\n"))

        return dict
    }
}

// MARK: - CrashStackFrame (Codable version of StackFrame)

/// Codable stack frame for crash persistence. StackFrame lives in PepperHangDetector
/// and isn't Codable, so we use our own type for disk serialization.
struct CrashStackFrame: Codable {
    let address: String
    let symbol: String?
    let image: String?
    let offset: UInt

    init(from frame: StackFrame) {
        self.address = String(format: "0x%lx", frame.address)
        self.symbol = frame.symbol
        self.image = frame.image
        self.offset = frame.offset
    }

    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "address": AnyCodable(address)
        ]
        if let symbol = symbol {
            dict["symbol"] = AnyCodable(symbol)
        }
        if let image = image {
            dict["image"] = AnyCodable(image)
        }
        if offset > 0 {
            dict["offset"] = AnyCodable(Int(offset))
        }
        return dict
    }

    var description: String {
        let sym = symbol ?? "???"
        let img = image ?? "???"
        return "\(img)  \(sym) + \(offset)"
    }
}
