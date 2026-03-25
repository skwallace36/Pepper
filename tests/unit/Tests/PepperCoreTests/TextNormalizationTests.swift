import XCTest
@testable import PepperCore

final class TextNormalizationTests: XCTestCase {

    // MARK: - pepperNormalized

    func test_plain_ascii_unchanged() {
        XCTAssertEqual("Hello World".pepperNormalized, "Hello World")
    }

    func test_curly_single_quotes_normalized() {
        XCTAssertEqual("\u{2018}hello\u{2019}".pepperNormalized, "'hello'")
    }

    func test_curly_double_quotes_normalized() {
        XCTAssertEqual("\u{201C}hello\u{201D}".pepperNormalized, "\"hello\"")
    }

    func test_en_dash_normalized() {
        XCTAssertEqual("2023\u{2013}2024".pepperNormalized, "2023-2024")
    }

    func test_em_dash_normalized() {
        XCTAssertEqual("yes\u{2014}no".pepperNormalized, "yes-no")
    }

    func test_nbsp_normalized_to_space() {
        XCTAssertEqual("hello\u{00A0}world".pepperNormalized, "hello world")
    }

    func test_multiple_normalizations_combined() {
        let input = "\u{201C}It\u{2019}s a 2023\u{2013}2024\u{00A0}thing\u{201D}"
        let expected = "\"It's a 2023-2024 thing\""
        XCTAssertEqual(input.pepperNormalized, expected)
    }

    func test_empty_string_unchanged() {
        XCTAssertEqual("".pepperNormalized, "")
    }

    // MARK: - pepperContains

    func test_contains_plain_match() {
        XCTAssertTrue("Hello World".pepperContains("world"))
    }

    func test_contains_case_insensitive() {
        XCTAssertTrue("Submit".pepperContains("submit"))
        XCTAssertTrue("CANCEL".pepperContains("cancel"))
    }

    func test_contains_curly_quotes_match_ascii() {
        // Searching for ASCII quote should match curly quote in source
        XCTAssertTrue("\u{201C}Login\u{201D}".pepperContains("\"Login\""))
    }

    func test_contains_ascii_matches_curly_in_query() {
        // Source has ASCII, query has curly — should still match
        XCTAssertTrue("\"Login\"".pepperContains("\u{201C}Login\u{201D}"))
    }

    func test_contains_partial_match() {
        XCTAssertTrue("Submit Order".pepperContains("Order"))
    }

    func test_contains_no_match() {
        XCTAssertFalse("Hello".pepperContains("Goodbye"))
    }

    func test_contains_empty_query_returns_false() {
        // localizedCaseInsensitiveContains("") returns false
        XCTAssertFalse("Hello".pepperContains(""))
    }

    func test_contains_nbsp_matches_space() {
        XCTAssertTrue("hello\u{00A0}world".pepperContains("hello world"))
    }

    // MARK: - pepperEquals

    func test_equals_exact_match() {
        XCTAssertTrue("Login".pepperEquals("Login"))
    }

    func test_equals_case_insensitive() {
        XCTAssertTrue("Login".pepperEquals("login"))
        XCTAssertTrue("LOGIN".pepperEquals("login"))
    }

    func test_equals_curly_quotes_match_ascii() {
        XCTAssertTrue("\u{2018}OK\u{2019}".pepperEquals("'OK'"))
    }

    func test_equals_not_equal_different_strings() {
        XCTAssertFalse("Login".pepperEquals("Logout"))
    }

    func test_equals_substring_does_not_match() {
        XCTAssertFalse("Submit Order".pepperEquals("Submit"))
    }

    func test_equals_empty_strings_match() {
        XCTAssertTrue("".pepperEquals(""))
    }

    func test_equals_en_dash_matches_hyphen() {
        XCTAssertTrue("2023\u{2013}2024".pepperEquals("2023-2024"))
    }
}
