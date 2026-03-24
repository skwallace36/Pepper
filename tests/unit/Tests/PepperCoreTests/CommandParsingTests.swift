import XCTest
@testable import PepperCore

final class CommandParsingTests: XCTestCase {

    // MARK: - PepperCommand decoding

    func test_decode_minimal_command() throws {
        let cmd = try decode(#"{"id":"1","cmd":"ping"}"#)
        XCTAssertEqual(cmd.id, "1")
        XCTAssertEqual(cmd.cmd, "ping")
        XCTAssertNil(cmd.params)
    }

    func test_decode_command_with_string_param() throws {
        let cmd = try decode(#"{"id":"2","cmd":"tap","params":{"label":"Submit"}}"#)
        XCTAssertEqual(cmd.params?["label"]?.stringValue, "Submit")
    }

    func test_decode_command_with_int_param() throws {
        let cmd = try decode(#"{"id":"3","cmd":"scroll","params":{"distance":100}}"#)
        XCTAssertEqual(cmd.params?["distance"]?.intValue, 100)
    }

    func test_decode_command_with_bool_param() throws {
        let cmd = try decode(#"{"id":"4","cmd":"tap","params":{"auto_idle":false}}"#)
        XCTAssertEqual(cmd.params?["auto_idle"]?.boolValue, false)
    }

    func test_decode_command_with_array_param() throws {
        let cmd = try decode(#"{"id":"5","cmd":"gesture","params":{"points":[1,2,3]}}"#)
        XCTAssertEqual(cmd.params?["points"]?.arrayValue?.count, 3)
        XCTAssertEqual(cmd.params?["points"]?[0]?.intValue, 1)
    }

    func test_decode_command_with_dict_param() throws {
        let cmd = try decode(#"{"id":"6","cmd":"tap","params":{"opts":{"x":10,"y":20}}}"#)
        XCTAssertEqual(cmd.params?["opts"]?["x"]?.intValue, 10)
        XCTAssertEqual(cmd.params?["opts"]?["y"]?.intValue, 20)
    }

    func test_decode_command_with_null_param() throws {
        let cmd = try decode(#"{"id":"7","cmd":"tap","params":{"label":null}}"#)
        XCTAssertTrue(cmd.params?["label"]?.isNull == true)
    }

    func test_decode_command_empty_params() throws {
        let cmd = try decode(#"{"id":"8","cmd":"ping","params":{}}"#)
        XCTAssertNotNil(cmd.params)
        XCTAssertEqual(cmd.params?.count, 0)
    }

    // MARK: - Malformed / invalid JSON

    func test_malformed_json_throws() {
        XCTAssertThrowsError(try decode("not valid json"))
    }

    func test_empty_json_object_throws() {
        // Missing required "id" and "cmd"
        XCTAssertThrowsError(try decode("{}"))
    }

    func test_missing_id_throws() {
        XCTAssertThrowsError(try decode(#"{"cmd":"ping"}"#))
    }

    func test_missing_cmd_throws() {
        XCTAssertThrowsError(try decode(#"{"id":"1"}"#))
    }

    func test_empty_string_throws() {
        XCTAssertThrowsError(try decode(""))
    }

    func test_array_root_throws() {
        XCTAssertThrowsError(try decode("[1,2,3]"))
    }

    // MARK: - PepperResponse

    func test_response_ok_no_data() {
        let r = PepperResponse.ok(id: "x")
        XCTAssertEqual(r.id, "x")
        XCTAssertEqual(r.status, .ok)
        XCTAssertNil(r.data)
    }

    func test_response_ok_with_data() {
        let r = PepperResponse.ok(id: "y", data: ["result": AnyCodable("done")])
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.data?["result"]?.stringValue, "done")
    }

    func test_response_error_sets_message() {
        let r = PepperResponse.error(id: "z", message: "boom")
        XCTAssertEqual(r.id, "z")
        XCTAssertEqual(r.status, .error)
        XCTAssertEqual(r.data?["message"]?.stringValue, "boom")
    }

    func test_response_roundtrip_via_json() throws {
        let original = PepperResponse.ok(id: "42", data: ["count": AnyCodable(7)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PepperResponse.self, from: data)
        XCTAssertEqual(decoded.id, "42")
        XCTAssertEqual(decoded.status, .ok)
        XCTAssertEqual(decoded.data?["count"]?.intValue, 7)
    }

    func test_response_error_roundtrip_via_json() throws {
        let original = PepperResponse.error(id: "e1", message: "not found")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PepperResponse.self, from: data)
        XCTAssertEqual(decoded.status, .error)
        XCTAssertEqual(decoded.data?["message"]?.stringValue, "not found")
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> PepperCommand {
        try JSONDecoder().decode(PepperCommand.self, from: Data(json.utf8))
    }
}
