import Foundation
import UIKit

/// Type classification, encoding/decoding of property values for PepperVarRegistry.
extension PepperVarRegistry {

    // MARK: - Type Classification

    /// Extract the generic type parameter from "Published<SomeType>".
    func extractGenericParam(from typeName: String) -> String {
        guard typeName.hasPrefix("Published<"), typeName.hasSuffix(">") else {
            return typeName
        }
        let start = typeName.index(typeName.startIndex, offsetBy: 10)  // "Published<".count
        let end = typeName.index(before: typeName.endIndex)
        return String(typeName[start..<end])
    }

    /// Classify a type name string into our VarType enum.
    func classifyType(_ typeName: String) -> (VarType, VarType?) {
        switch typeName {
        case "Int": return (.int, nil)
        case "Double": return (.double, nil)
        case "CGFloat": return (.cgfloat, nil)
        case "Bool": return (.bool, nil)
        case "String": return (.string, nil)
        case "CGSize": return (.cgSize, nil)
        case "EdgeInsets": return (.edgeInsets, nil)
        case "Color": return (.color, nil)
        default:
            if typeName.hasPrefix("Optional<") {
                let innerName = String(typeName.dropFirst(9).dropLast(1))
                let (innerType, _) = classifyType(innerName)
                return (.optional, innerType)
            }
            return (.unknown, nil)
        }
    }

    // MARK: - Serialization (Encode)

    /// Serialize a value to AnyCodable based on its classified type.
    // swiftlint:disable:next cyclomatic_complexity
    func serializeValue(_ value: Any?, type: VarType, innerType: VarType?) -> AnyCodable? {
        guard let value = value else { return AnyCodable(NSNull()) }

        // Handle optionals: unwrap the Optional<T>
        if type == .optional {
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                if let first = mirror.children.first {
                    return serializeValue(first.value, type: innerType ?? .unknown, innerType: nil)
                } else {
                    return AnyCodable(NSNull())  // nil
                }
            }
            // Not actually Optional — serialize with inner type
            return serializeValue(value, type: innerType ?? .unknown, innerType: nil)
        }

        switch type {
        case .int:
            if let v = value as? Int { return AnyCodable(v) }
        case .double:
            if let v = value as? Double { return AnyCodable(v) }
        case .cgfloat:
            if let v = value as? CGFloat { return AnyCodable(Double(v)) }
        case .bool:
            if let v = value as? Bool { return AnyCodable(v) }
        case .string:
            if let v = value as? String { return AnyCodable(v) }
        case .cgSize:
            if let v = value as? CGSize {
                return AnyCodable([
                    "width": AnyCodable(Double(v.width)),
                    "height": AnyCodable(Double(v.height)),
                ])
            }
        case .edgeInsets:
            if let v = value as? UIEdgeInsets {
                return AnyCodable([
                    "top": AnyCodable(Double(v.top)),
                    "leading": AnyCodable(Double(v.left)),
                    "bottom": AnyCodable(Double(v.bottom)),
                    "trailing": AnyCodable(Double(v.right)),
                ])
            }
        case .color:
            // Color → hex string
            return AnyCodable(String(describing: value))
        case .optional:
            break  // handled above
        case .unknown:
            return AnyCodable(String(describing: value))
        }

        // Fallback: string description
        return AnyCodable(String(describing: value))
    }

    // MARK: - Deserialization (Decode)

    /// Convert a JSON AnyCodable to the target Swift type.
    func deserializeValue(_ json: AnyCodable, type: VarType, innerType: VarType?) -> Any? {
        // Handle null for optionals
        if type == .optional {
            if json.isNull {
                return NSNull()  // will be written as nil
            }
            return deserializeValue(json, type: innerType ?? .unknown, innerType: nil)
        }

        switch type {
        case .int:
            return json.intValue
        case .double:
            return json.doubleValue
        case .cgfloat:
            if let v = json.doubleValue { return CGFloat(v) }
            return nil
        case .bool:
            return json.boolValue
        case .string:
            return json.stringValue
        case .cgSize:
            if let dict = json.dictValue,
                let w = dict["width"]?.doubleValue,
                let h = dict["height"]?.doubleValue
            {
                return CGSize(width: w, height: h)
            }
            return nil
        case .edgeInsets:
            if let dict = json.dictValue,
                let top = dict["top"]?.doubleValue,
                let leading = dict["leading"]?.doubleValue,
                let bottom = dict["bottom"]?.doubleValue,
                let trailing = dict["trailing"]?.doubleValue
            {
                return UIEdgeInsets(top: top, left: leading, bottom: bottom, right: trailing)
            }
            return nil
        case .color:
            // Accept hex string — return as-is, actual Color conversion is complex
            return json.stringValue
        case .optional:
            return nil  // handled above
        case .unknown:
            return nil
        }
    }

    // MARK: - Published Value Extraction

    /// Extract the wrapped value from a Published<T> instance.
    /// Published<T> has two internal storage states:
    ///   - .value(T) — before any subscriber attaches
    ///   - .publisher(CurrentValueSubject<T, Never>) — after first subscription
    func extractPublishedValue(_ published: Any) -> Any? {
        let mirror = Mirror(reflecting: published)

        // Try direct "storage" child (Published internal layout)
        for child in mirror.children {
            let label = child.label ?? ""
            if label == "storage" || label == "_storage" {
                let storageMirror = Mirror(reflecting: child.value)
                // Enum case: check children
                for storageChild in storageMirror.children {
                    let sLabel = storageChild.label ?? ""
                    if sLabel == "value" || sLabel == ".0" {
                        // .value(T) case — the T is directly here
                        return storageChild.value
                    }
                    if sLabel == "publisher" || sLabel == ".0" {
                        // .publisher case — it's a CurrentValueSubject, get its value
                        let pubMirror = Mirror(reflecting: storageChild.value)
                        for pubChild in pubMirror.children {
                            let pLabel = pubChild.label ?? ""
                            if pLabel == "value" || pLabel == "_value" || pLabel == "currentValue" {
                                return pubChild.value
                            }
                        }
                        // Try KVC on the subject
                        let subject = storageChild.value as AnyObject
                        if subject.responds(to: NSSelectorFromString("value")) {
                            return subject.value(forKey: "value")
                        }
                    }
                }
                // If storage itself contains the value directly
                return child.value
            }
        }

        // Fallback: try to find value directly in mirror children
        for child in mirror.children {
            if child.label == "value" || child.label == "wrappedValue" {
                return child.value
            }
        }

        // Last resort: the first child might be the storage enum
        if let first = mirror.children.first {
            return extractValueFromEnum(first.value)
        }

        return nil
    }

    /// Try to extract value from a Swift enum storage.
    func extractValueFromEnum(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        if let first = mirror.children.first {
            // Enum associated values appear as .0, .1, etc.
            return first.value
        }
        return value
    }

    // MARK: - Write Strategies

    /// Write value into Published<T>'s internal CurrentValueSubject.
    func writeViaPublishedStorage(published: Any, value: Any, isNil: Bool) -> String? {
        let mirror = Mirror(reflecting: published)

        for child in mirror.children {
            let label = child.label ?? ""
            if label == "storage" || label == "_storage" {
                let storageMirror = Mirror(reflecting: child.value)
                for storageChild in storageMirror.children {
                    // .publisher(CurrentValueSubject) case
                    let subject = storageChild.value as AnyObject
                    if subject.responds(to: NSSelectorFromString("value")) {
                        if isNil {
                            subject.setValue(nil, forKey: "value")
                        } else {
                            subject.setValue(value, forKey: "value")
                        }
                        return nil  // success
                    }
                }
            }
        }

        return "Could not find CurrentValueSubject in Published storage."
    }

    /// Write to raw memory at the ivar offset. Unsafe but works for pure Swift classes.
    func writeRawMemory(
        ptr: UnsafeMutableRawPointer, offset: Int, value: Any,
        type: VarType, innerType: VarType?
    ) -> String? {
        let effectiveType = type == .optional ? (innerType ?? .unknown) : type

        switch effectiveType {
        case .int:
            guard let v = value as? Int else { return "Type mismatch: expected Int" }
            ptr.storeBytes(of: v, toByteOffset: offset, as: Int.self)
        case .double:
            guard let v = value as? Double else { return "Type mismatch: expected Double" }
            ptr.storeBytes(of: v, toByteOffset: offset, as: Double.self)
        case .cgfloat:
            guard let v = value as? CGFloat else { return "Type mismatch: expected CGFloat" }
            ptr.storeBytes(of: v, toByteOffset: offset, as: CGFloat.self)
        case .bool:
            guard let v = value as? Bool else { return "Type mismatch: expected Bool" }
            ptr.storeBytes(of: v, toByteOffset: offset, as: Bool.self)
        default:
            return "Raw memory write not supported for type '\(effectiveType.rawValue)'"
        }

        return nil  // success
    }

    // MARK: - Value Description

    /// Describe a value for mirror output — handles optionals, collections, etc.
    func describeValue(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)

        // Unwrap optionals
        if mirror.displayStyle == .optional {
            if let first = mirror.children.first {
                return describeValue(first.value)
            }
            return "nil"
        }

        // Short description for known simple types
        if value is String || value is Int || value is Double || value is Bool || value is CGFloat {
            return String(describing: value)
        }

        // Collections — show count + first few items
        if mirror.displayStyle == .collection || mirror.displayStyle == .set {
            let items = mirror.children.prefix(3).map { describeValue($0.value) }
            let suffix = mirror.children.count > 3 ? ", ... (\(mirror.children.count) total)" : ""
            return "[\(items.joined(separator: ", "))\(suffix)]"
        }

        // Dictionaries
        if mirror.displayStyle == .dictionary {
            return "[\(mirror.children.count) entries]"
        }

        return String(describing: value)
    }

    /// Describe an AnyCodable value as a string.
    func describeAnyCodable(_ value: AnyCodable) -> String {
        if let s = value.stringValue { return s }
        if let i = value.intValue { return String(i) }
        if let d = value.doubleValue { return String(d) }
        if let b = value.boolValue { return String(b) }
        return String(describing: value.value)
    }
}
