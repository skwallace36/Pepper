import Foundation

/// Inbound command from a connected client.
struct PepperCommand: Codable {
    let id: String
    let cmd: String
    let params: [String: AnyCodable]?
}

/// Outbound response to a command.
struct PepperResponse: Codable {
    let id: String
    let status: Status
    let data: [String: AnyCodable]?

    enum Status: String, Codable {
        case ok
        case error
    }

    static func ok(id: String, data: [String: AnyCodable]? = nil) -> PepperResponse {
        PepperResponse(id: id, status: .ok, data: data)
    }

    static func error(id: String, message: String) -> PepperResponse {
        PepperResponse(id: id, status: .error, data: ["message": AnyCodable(message)])
    }

    /// Enriched error for element-not-found conditions.
    /// Includes up to 5 similar on-screen labels, an actionable suggestion,
    /// and optional structured diagnostics (candidate count, rejection reasons).
    /// Must be called on the main thread.
    static func elementNotFound(
        id: String,
        message: String,
        query: String? = nil,
        suggestion: String = "Try `look` to see current screen state",
        diagnostics: [String: AnyCodable] = [:]
    ) -> PepperResponse {
        let found = PepperElementSuggestions.nearbyLabels(for: query, maxResults: 5)
        var data: [String: AnyCodable] = ["message": AnyCodable(message)]
        if !found.isEmpty {
            data["found"] = AnyCodable(found.map { AnyCodable($0) })
        }
        data["suggestion"] = AnyCodable(suggestion)
        for (key, value) in diagnostics {
            data[key] = value
        }
        return PepperResponse(id: id, status: .error, data: data)
    }
}

/// Outbound event pushed to clients.
struct PepperEvent: Codable {
    let event: String
    let data: [String: AnyCodable]?
}

// MARK: - AnyCodable

/// Type-erased Codable wrapper for heterogeneous JSON values.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        // Recursively normalize containers so encoding works correctly.
        // Without this, types like [[String: AnyCodable]] or [String: [String: AnyCodable]]
        // fall through to the default nil case during encoding.
        switch value {
        case let dict as [String: AnyCodable]:
            self.value = dict
        case let dict as [String: Any]:
            self.value = dict.mapValues { AnyCodable($0) }
        case let array as [AnyCodable]:
            self.value = array
        case let array as [Any]:
            self.value = array.map { AnyCodable($0) }
        default:
            self.value = value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String: try container.encode(string)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let bool as Bool: try container.encode(bool)
        case let dict as [String: AnyCodable]: try container.encode(dict)
        case let array as [AnyCodable]: try container.encode(array)
        case is NSNull: try container.encodeNil()
        default: try container.encodeNil()
        }
    }
}

// MARK: - Equatable

extension AnyCodable: Equatable {
    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case (let l as String, let r as String): return l == r
        case (let l as Int, let r as Int): return l == r
        case (let l as Double, let r as Double): return l == r
        case (let l as Bool, let r as Bool): return l == r
        case (let l as [String: AnyCodable], let r as [String: AnyCodable]): return l == r
        case (let l as [AnyCodable], let r as [AnyCodable]): return l == r
        case (is NSNull, is NSNull): return true
        default: return false
        }
    }
}

// MARK: - Hashable

extension AnyCodable: Hashable {
    func hash(into hasher: inout Hasher) {
        switch value {
        case let v as String: hasher.combine(v)
        case let v as Int: hasher.combine(v)
        case let v as Double: hasher.combine(v)
        case let v as Bool: hasher.combine(v)
        case let v as [String: AnyCodable]: hasher.combine(v)
        case let v as [AnyCodable]: hasher.combine(v)
        default: hasher.combine(0)
        }
    }
}

// MARK: - ExpressibleByLiteral Conformances

extension AnyCodable: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self.init(value)
    }
}

extension AnyCodable: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self.init(value)
    }
}

extension AnyCodable: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self.init(value)
    }
}

extension AnyCodable: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self.init(value)
    }
}

extension AnyCodable: ExpressibleByNilLiteral {
    init(nilLiteral: ()) {
        self.init(NSNull())
    }
}

extension AnyCodable: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, AnyCodable)...) {
        self.init(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension AnyCodable: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: AnyCodable...) {
        self.init(elements)
    }
}

// MARK: - Typed Accessors

extension AnyCodable {

    /// The underlying value as a String, or nil.
    var stringValue: String? {
        value as? String
    }

    /// The underlying value as an Int, or nil. Handles NSNumber conversion.
    var intValue: Int? {
        if let v = value as? Int { return v }
        if let v = value as? NSNumber { return v.intValue }
        return nil
    }

    /// The underlying value as a Double, or nil. Handles NSNumber conversion.
    var doubleValue: Double? {
        if let v = value as? Double { return v }
        if let v = value as? NSNumber { return v.doubleValue }
        return nil
    }

    /// The underlying value as a Bool, or nil. Handles NSNumber conversion.
    var boolValue: Bool? {
        if let v = value as? Bool { return v }
        if let v = value as? NSNumber {
            // NSNumber wraps bools as 0/1; check the objcType
            if String(cString: v.objCType) == "c" || String(cString: v.objCType) == "B" {
                return v.boolValue
            }
        }
        return nil
    }

    /// The underlying value as an array of AnyCodable, or nil.
    var arrayValue: [AnyCodable]? {
        value as? [AnyCodable]
    }

    /// The underlying value as a dictionary, or nil.
    var dictValue: [String: AnyCodable]? {
        value as? [String: AnyCodable]
    }

    /// Whether this value is null.
    var isNull: Bool {
        value is NSNull
    }

    /// Recursively convert to plain Swift types suitable for JSONSerialization.
    var jsonObject: Any {
        switch value {
        case let dict as [String: AnyCodable]:
            return dict.mapValues { $0.jsonObject }
        case let array as [AnyCodable]:
            return array.map { $0.jsonObject }
        default:
            return value
        }
    }

    // MARK: - Subscript

    /// Dictionary-style subscript for nested access.
    subscript(key: String) -> AnyCodable? {
        dictValue?[key]
    }

    /// Array-style subscript for indexed access.
    subscript(index: Int) -> AnyCodable? {
        guard let arr = arrayValue, index >= 0, index < arr.count else { return nil }
        return arr[index]
    }
}

// MARK: - Binary Payload Storage

extension PepperResponse {
    /// Thread-safe binary payload storage. Handlers that want binary frame delivery
    /// set a payload here keyed by response ID. The server checks and clears this
    /// after encoding the response, sending a binary WebSocket frame instead of text.
    private static var _binaryPayloads: [String: Data] = [:]
    private static let _lock = NSLock()

    /// Attach a binary payload to be sent as a binary WebSocket frame alongside
    /// the JSON header for the given response ID.
    static func setBinaryPayload(_ data: Data, for responseId: String) {
        _lock.lock()
        _binaryPayloads[responseId] = data
        _lock.unlock()
    }

    /// Remove and return the binary payload for a response ID, if any.
    static func takeBinaryPayload(for responseId: String) -> Data? {
        _lock.lock()
        let data = _binaryPayloads.removeValue(forKey: responseId)
        _lock.unlock()
        return data
    }
}

// MARK: - CustomStringConvertible

extension AnyCodable: CustomStringConvertible {
    var description: String {
        switch value {
        case let v as String: return "\"\(v)\""
        case let v as Int: return "\(v)"
        case let v as Double: return "\(v)"
        case let v as Bool: return "\(v)"
        case let v as [String: AnyCodable]: return "\(v)"
        case let v as [AnyCodable]: return "\(v)"
        case is NSNull: return "null"
        default: return "\(value)"
        }
    }
}
