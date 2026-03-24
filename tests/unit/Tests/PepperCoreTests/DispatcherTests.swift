import XCTest
@testable import PepperCore

final class DispatcherTests: XCTestCase {

    var dispatcher = TestDispatcher()

    override func setUp() {
        super.setUp()
        dispatcher = TestDispatcher()
    }

    // MARK: - Command routing

    func test_known_command_invokes_handler() {
        var invoked = false
        dispatcher.register("ping") { cmd in
            invoked = true
            return .ok(id: cmd.id)
        }
        _ = dispatcher.dispatch(cmd("ping"))
        XCTAssertTrue(invoked)
    }

    func test_handler_receives_correct_command_id() {
        dispatcher.register("echo") { cmd in .ok(id: cmd.id) }
        let response = dispatcher.dispatch(cmd("echo", id: "abc-123"))
        XCTAssertEqual(response.id, "abc-123")
    }

    func test_handler_receives_params() {
        var received: [String: AnyCodable]?
        dispatcher.register("inspect") { cmd in
            received = cmd.params
            return .ok(id: cmd.id)
        }
        _ = dispatcher.dispatch(
            PepperCommand(id: "1", cmd: "inspect", params: ["key": AnyCodable("val")])
        )
        XCTAssertEqual(received?["key"]?.stringValue, "val")
    }

    func test_routes_to_correct_handler_among_multiple() {
        var pingCalled = false
        var tapCalled = false
        dispatcher.register("ping") { _ in pingCalled = true; return .ok(id: "x") }
        dispatcher.register("tap")  { _ in tapCalled  = true; return .ok(id: "x") }

        _ = dispatcher.dispatch(cmd("ping"))
        XCTAssertTrue(pingCalled)
        XCTAssertFalse(tapCalled)

        _ = dispatcher.dispatch(cmd("tap"))
        XCTAssertTrue(tapCalled)
    }

    func test_handler_response_status_is_forwarded() {
        dispatcher.register("good") { cmd in .ok(id: cmd.id) }
        dispatcher.register("bad")  { cmd in .error(id: cmd.id, message: "fail") }

        XCTAssertEqual(dispatcher.dispatch(cmd("good")).status, .ok)
        XCTAssertEqual(dispatcher.dispatch(cmd("bad")).status, .error)
    }

    // MARK: - Unknown command handling

    func test_unknown_command_returns_error() {
        let response = dispatcher.dispatch(cmd("nonexistent"))
        XCTAssertEqual(response.status, .error)
    }

    func test_unknown_command_error_message_names_the_command() {
        let response = dispatcher.dispatch(cmd("mystery_cmd"))
        XCTAssertEqual(
            response.data?["message"]?.stringValue,
            "Unknown command: mystery_cmd"
        )
    }

    func test_unknown_command_preserves_id() {
        let response = dispatcher.dispatch(cmd("nope", id: "req-99"))
        XCTAssertEqual(response.id, "req-99")
    }

    func test_empty_command_name_returns_error() {
        let response = dispatcher.dispatch(cmd(""))
        XCTAssertEqual(response.status, .error)
    }

    // MARK: - Timeout behavior

    func test_default_timeout_is_10_seconds() {
        dispatcher.register("fast") { cmd in .ok(id: cmd.id) }
        XCTAssertEqual(dispatcher.timeout(for: "fast"), 10.0)
    }

    func test_custom_timeout_handler() {
        struct SlowHandler: PepperHandler {
            let commandName = "slow"
            var timeout: TimeInterval { 60.0 }
            func handle(_ command: PepperCommand) -> PepperResponse { .ok(id: command.id) }
        }
        dispatcher.register(SlowHandler())
        XCTAssertEqual(dispatcher.timeout(for: "slow"), 60.0)
    }

    func test_unknown_command_timeout_returns_default() {
        XCTAssertEqual(dispatcher.timeout(for: "ghost"), 10.0)
    }

    // MARK: - Registration

    func test_registeredCommands_lists_all() {
        dispatcher.register("ping") { cmd in .ok(id: cmd.id) }
        dispatcher.register("tap")  { cmd in .ok(id: cmd.id) }
        XCTAssertTrue(dispatcher.registeredCommands.contains("ping"))
        XCTAssertTrue(dispatcher.registeredCommands.contains("tap"))
    }

    func test_registeredCommands_is_sorted() {
        dispatcher.register("zzz") { cmd in .ok(id: cmd.id) }
        dispatcher.register("aaa") { cmd in .ok(id: cmd.id) }
        let cmds = dispatcher.registeredCommands
        XCTAssertEqual(cmds, cmds.sorted())
    }

    func test_re_registering_handler_overwrites_previous() {
        dispatcher.register("ping") { _ in .error(id: "x", message: "old") }
        dispatcher.register("ping") { cmd in .ok(id: cmd.id) }
        XCTAssertEqual(dispatcher.dispatch(cmd("ping")).status, .ok)
    }

    // MARK: - Helpers

    private func cmd(_ name: String, id: String = "1") -> PepperCommand {
        PepperCommand(id: id, cmd: name, params: nil)
    }
}
