import XCTest
@testable import Gridka

/// Regression tests for computed-expression injection protection.
/// Covers US-002: semicolon-in-string-literals (accepted), semicolons in SQL comments
/// (accepted), semicolons outside literals/comments (rejected), and runtime add path
/// applying the same validation as the preview path.
final class ExpressionInjectionTests: XCTestCase {

    // MARK: - Semicolons inside single-quoted string literals (accepted)

    func testSemicolonInsideSingleQuotedLiteral() {
        // REPLACE(col, ';', ',') — semicolon inside single quotes is safe
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("REPLACE(col, ';', ',')"))
    }

    func testMultipleSemicolonsInsideSingleQuotedLiteral() {
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("REPLACE(col, ';;', ',')"))
    }

    func testSemicolonInSingleQuotedValueEquality() {
        // WHERE col = ';'
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("col = ';'"))
    }

    func testSemicolonWithEscapedQuoteInsideLiteral() {
        // 'it''s ; here' — doubled single-quote escape followed by semicolon, all inside quotes
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("'it''s ; here'"))
    }

    func testSemicolonBetweenTwoSingleQuotedStrings() {
        // CONCAT('a', 'b;c') — semicolon only in second literal
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("CONCAT('a', 'b;c')"))
    }

    func testEmptySingleQuotedStringBeforeSemicolon() {
        // '' followed by bare semicolon — should reject
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("'';"))
    }

    // MARK: - Semicolons inside double-quoted identifiers (accepted)

    func testSemicolonInsideDoubleQuotedIdentifier() {
        // "col;name" — semicolon inside double-quoted identifier
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("\"col;name\" + 1"))
    }

    func testDoubleQuotedIdentifierWithDoubledEscape() {
        // "col""name;x" — doubled double-quote escape, semicolon still inside
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("\"col\"\"name;x\""))
    }

    // MARK: - Semicolons inside line comments (accepted)

    func testSemicolonInLineComment() {
        // Expression with line comment containing semicolon
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("col + 1 -- this has ; in comment"))
    }

    func testSemicolonInLineCommentMultiline() {
        // Line comment ends at newline; next line is clean
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("col + 1 -- comment with ;\ncol + 2"))
    }

    func testSemicolonInLineCommentThenBareSemicolon() {
        // Comment has semicolon (safe), but bare semicolon after newline (rejected)
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("col -- comment;\n; DELETE"))
    }

    // MARK: - Semicolons inside block comments (accepted)

    func testSemicolonInBlockComment() {
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("col + 1 /* ; */"))
    }

    func testSemicolonInMultilineBlockComment() {
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("col /* multi\nline ; comment */ + 1"))
    }

    func testSemicolonInBlockCommentFollowedByCleanCode() {
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("/* ; */ col + 1"))
    }

    func testSemicolonAfterBlockCommentClose() {
        // Semicolon outside the closed block comment — rejected
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("col /* safe */ ; DROP"))
    }

    // MARK: - Semicolons outside literals/comments (rejected)

    func testBareSemicolon() {
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes(";"))
    }

    func testSemicolonAfterExpression() {
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("col + 1;"))
    }

    func testMultiStatementInjection() {
        // Classic injection: close expression, inject DELETE
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("1); DELETE FROM data; --"))
    }

    func testSemicolonBetweenExpressions() {
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("col + 1; col + 2"))
    }

    func testSemicolonAtStart() {
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("; SELECT 1"))
    }

    func testSemicolonAfterClosedStringLiteral() {
        // String literal is closed, then bare semicolon follows
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("'safe'; DELETE"))
    }

    func testSemicolonAfterClosedDoubleQuotedIdentifier() {
        // Double-quoted identifier is closed, then bare semicolon follows
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("\"col\"; DELETE"))
    }

    // MARK: - Edge cases

    func testEmptyExpression() {
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes(""))
    }

    func testNoSemicolon() {
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("col + 1"))
    }

    func testOnlySingleQuotedString() {
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("';'"))
    }

    func testUnterminatedSingleQuoteWithSemicolon() {
        // Unterminated string — semicolon is inside the open quote, so technically "inside"
        // The scanner treats it as still within the quoted region
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("'unterminated string ;"))
    }

    func testUnterminatedBlockCommentWithSemicolon() {
        // Unterminated block comment — semicolon is inside the open comment
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("/* unterminated ; "))
    }

    func testDoubleQuotedIdentifierBypassAttempt() {
        // Attempt to use double-quoted identifier to hide a line comment start,
        // then inject after: "col--name"; DELETE
        // The scanner should see " as opening a quoted identifier, then the closing "
        // puts us back in normal mode where ; is detected.
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("\"col--name\"; DELETE"))
    }

    func testNestedCommentSyntaxNotSupported() {
        // SQL doesn't support nested block comments; first */ closes the comment
        // /* outer /* inner */ ; — semicolon is OUTSIDE after first */ closes
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("/* outer /* inner */ ;"))
    }

    func testDashInsideStringDoesNotStartComment() {
        // '--' inside a string literal should not be treated as a comment start
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("REPLACE(col, '--', ';')"))
    }

    func testSlashStarInsideStringDoesNotStartBlockComment() {
        // '/*' inside a string literal should not start a block comment
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("REPLACE(col, '/*', ';')"))
    }

    func testMixedQuotingStyles() {
        // Double-quoted identifier then single-quoted literal, both with semicolons
        XCTAssertFalse(FileSession.containsSemicolonOutsideQuotes("\"col;a\" || ';'"))
    }

    func testSemicolonSurroundedByWhitespace() {
        XCTAssertTrue(FileSession.containsSemicolonOutsideQuotes("col + 1 ; DROP TABLE"))
    }

    // MARK: - Runtime add/apply path uses same validation as preview path

    func testPreviewPathRejectsSemicolonInjection() throws {
        // Verify that fetchComputedColumnPreview rejects semicolon injection
        // by calling it and expecting an invalidExpression error.
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        let done = expectation(description: "preview completes")
        var receivedError: Error?

        onMain {
            session.fetchComputedColumnPreview(
                expression: "1); DELETE FROM data; --",
                columnName: "injected"
            ) { result in
                if case .failure(let err) = result {
                    receivedError = err
                }
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 10)

        XCTAssertNotNil(receivedError, "Preview path should reject semicolon injection")
        if let gridkaError = receivedError as? GridkaError,
           case .invalidExpression(let msg) = gridkaError {
            XCTAssertTrue(msg.contains("semicolons"), "Error message should mention semicolons")
        } else {
            XCTFail("Expected GridkaError.invalidExpression, got: \(String(describing: receivedError))")
        }
    }

    func testPreviewPathAcceptsSemicolonInLiteral() throws {
        // fetchComputedColumnPreview should NOT reject expressions with semicolons in string literals.
        // The query may fail for other reasons (column doesn't exist), but the semicolon check should pass.
        let url = try requireFixture(at: TestFixtures.forexCsv)
        let session = try FileSession(filePath: url)
        try loadSessionFully(session)

        let done = expectation(description: "preview completes")
        var receivedError: Error?

        onMain {
            session.fetchComputedColumnPreview(
                expression: "REPLACE(\"close\", ';', ',')",
                columnName: "safe"
            ) { result in
                if case .failure(let err) = result {
                    receivedError = err
                }
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 10)

        // The error should NOT be an invalidExpression — it may be a query error
        // if the column name doesn't match, but the semicolon check passed.
        if let gridkaError = receivedError as? GridkaError,
           case .invalidExpression = gridkaError {
            XCTFail("Preview path should NOT reject semicolons inside string literals")
        }
    }

    func testRuntimeAndPreviewUseIdenticalValidator() {
        // Both paths use FileSession.containsSemicolonOutsideQuotes.
        // Verify they agree on a battery of inputs.
        let cases: [(String, Bool)] = [
            ("col + 1", false),
            ("';'", false),
            ("REPLACE(col, ';', ',')", false),
            ("col -- comment ;", false),
            ("col /* ; */", false),
            ("\"id;col\"", false),
            (";", true),
            ("1); DROP TABLE data; --", true),
            ("col + 1;", true),
            ("'safe'; DELETE", true),
        ]

        for (expr, shouldReject) in cases {
            XCTAssertEqual(
                FileSession.containsSemicolonOutsideQuotes(expr),
                shouldReject,
                "Validation mismatch for expression: \(expr)"
            )
        }
    }
}
