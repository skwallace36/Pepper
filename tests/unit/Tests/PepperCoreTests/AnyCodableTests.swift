import XCTest
@testable import PepperCore

final class AnyCodableTests: XCTestCase {

    // MARK: - Decoding

    func test_decode_string() throws {
        let value = try decode(#""hello""#)
        XCTAssertEqual(value.stringValue, "hello")
    }

    func test_decode_int() throws {
        let value = try decode("42")
        XCTAssertEqual(value.intValue, 42)
    }

    func test_decode_bool_true() throws {
        let value = try decode("true")
        XCTAssertEqual(value.boolValue, true)
    }

    func test_decode_bool_false() throws {
        let value = try decode("false")
        XCTAssertEqual(value.boolValue, false)
    }

    func test_decode_array() throws {
        let value = try decode("[1, 2, 3]")
        let arr = try XCTUnwrap(value.arrayValue)
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[0].intValue, 1)
        XCTAssertEqual(arr[2].intValue, 3)
    }

    func test_decode_dict() throws {
        let value = try decode(#"{"key":"value"}"#)
        XCTAssertEqual(value.dictValue?["key"]?.stringValue, "value")
    }

    func test_decode_null() throws {
        let value = try decode("null")
        XCTAssertTrue(value.isNull)
    }

    // MARK: - Encoding round-trips

    func test_roundtrip_string() throws {
        try assertRoundtrip(AnyCodable("hello")) { XCTAssertEqual($0.stringValue, "hello") }
    }

    func test_roundtrip_int() throws {
        try assertRoundtrip(AnyCodable(42)) { XCTAssertEqual($0.intValue, 42) }
    }

    func test_roundtrip_bool() throws {
        try assertRoundtrip(AnyCodable(true)) { XCTAssertEqual($0.boolValue, true) }
    }

    func test_roundtrip_null() throws {
        try assertRoundtrip(AnyCodable(NSNull())) { XCTAssertTrue($0.isNull) }
    }

    func test_roundtrip_array() throws {
        let original = AnyCodable([AnyCodable(1), AnyCodable("two"), AnyCodable(true)])
        try assertRoundtrip(original) { decoded in
            let arr = try XCTUnwrap(decoded.arrayValue)
            XCTAssertEqual(arr.count, 3)
            XCTAssertEqual(arr[0].intValue, 1)
            XCTAssertEqual(arr[1].stringValue, "two")
            XCTAssertEqual(arr[2].boolValue, true)
        }
    }

    func test_roundtrip_dict() throws {
        let original: AnyCodable = ["x": AnyCodable(10), "y": AnyCodable("z")]
        try assertRoundtrip(original) { decoded in
            XCTAssertEqual(decoded["x"]?.intValue, 10)
            XCTAssertEqual(decoded["y"]?.stringValue, "z")
        }
    }

    func test_roundtrip_nested_dict_in_array() throws {
        let original = AnyCodable([AnyCodable(["a": AnyCodable(1)])])
        try assertRoundtrip(original) { decoded in
            XCTAssertEqual(decoded[0]?["a"]?.intValue, 1)
        }
    }

    // MARK: - Typed accessors

    func test_subscript_dict() {
        let value: AnyCodable = ["name": "Alice", "age": 30]
        XCTAssertEqual(value["name"]?.stringValue, "Alice")
        XCTAssertEqual(value["age"]?.intValue, 30)
        XCTAssertNil(value["missing"])
    }

    func test_subscript_array() {
        let value: AnyCodable = [AnyCodable("a"), AnyCodable("b"), AnyCodable("c")]
        XCTAssertEqual(value[0]?.stringValue, "a")
        XCTAssertEqual(value[2]?.stringValue, "c")
        XCTAssertNil(value[5])
        XCTAssertNil(value[-1])
    }

    func test_double_value() throws {
        let value = try decode("3.14")
        XCTAssertEqual(value.doubleValue ?? 0, 3.14, accuracy: 0.001)
    }

    // MARK: - Equatable

    func test_equality_string() {
        XCTAssertEqual(AnyCodable("hello"), AnyCodable("hello"))
        XCTAssertNotEqual(AnyCodable("hello"), AnyCodable("world"))
    }

    func test_equality_int() {
        XCTAssertEqual(AnyCodable(1), AnyCodable(1))
        XCTAssertNotEqual(AnyCodable(1), AnyCodable(2))
    }

    func test_equality_bool() {
        XCTAssertEqual(AnyCodable(true), AnyCodable(true))
        XCTAssertNotEqual(AnyCodable(true), AnyCodable(false))
    }

    func test_equality_null() {
        XCTAssertEqual(AnyCodable(NSNull()), AnyCodable(NSNull()))
    }

    // MARK: - ExpressibleByLiteral

    func test_literal_string() {
        let v: AnyCodable = "test"
        XCTAssertEqual(v.stringValue, "test")
    }

    func test_literal_int() {
        let v: AnyCodable = 99
        XCTAssertEqual(v.intValue, 99)
    }

    func test_literal_bool() {
        let v: AnyCodable = false
        XCTAssertEqual(v.boolValue, false)
    }

    func test_literal_float() {
        let v: AnyCodable = 2.5
        XCTAssertEqual(v.doubleValue ?? 0, 2.5, accuracy: 0.001)
    }

    func test_literal_nil() {
        let v: AnyCodable = nil
        XCTAssertTrue(v.isNull)
    }

    func test_literal_dict() {
        let v: AnyCodable = ["k": "v"]
        XCTAssertEqual(v["k"]?.stringValue, "v")
    }

    func test_literal_array() {
        let v: AnyCodable = [AnyCodable(1), AnyCodable(2)]
        XCTAssertEqual(v.arrayValue?.count, 2)
    }

    // MARK: - jsonObject

    func test_jsonObject_string() {
        XCTAssertEqual(AnyCodable("hi").jsonObject as? String, "hi")
    }

    func test_jsonObject_dict() {
        let v: AnyCodable = ["n": AnyCodable(7)]
        let obj = v.jsonObject as? [String: Any]
        XCTAssertEqual(obj?["n"] as? Int, 7)
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    }

    private func assertRoundtrip(
        _ value: AnyCodable,
        file: StaticString = #file,
        line: UInt = #line,
        check: (AnyCodable) throws -> Void
    ) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        try check(decoded)
    }
}
