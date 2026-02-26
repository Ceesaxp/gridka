import XCTest
@testable import Gridka

final class QueryCoordinatorTests: XCTestCase {

    private var coordinator: QueryCoordinator!
    private var sampleColumns: [ColumnDescriptor]!

    override func setUp() {
        super.setUp()
        coordinator = QueryCoordinator()
        sampleColumns = [
            ColumnDescriptor(name: "name", duckDBType: .varchar, displayType: .text, index: 0),
            ColumnDescriptor(name: "age", duckDBType: .integer, displayType: .integer, index: 1),
            ColumnDescriptor(name: "salary", duckDBType: .double, displayType: .float, index: 2),
            ColumnDescriptor(name: "active", duckDBType: .boolean, displayType: .boolean, index: 3),
            ColumnDescriptor(name: "hired", duckDBType: .date, displayType: .date, index: 4),
        ]
    }

    // MARK: - Basic Query (No Filters/Sort)

    func testBareSelect() {
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 1000
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM data LIMIT 500 OFFSET 0")
    }

    func testBareSelectWithOffset() {
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 5000
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 1000..<1500)
        XCTAssertEqual(sql, "SELECT * FROM data LIMIT 500 OFFSET 1000")
    }

    func testCountQueryNoFilters() {
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 1000
        )
        let sql = coordinator.buildCountQuery(for: state, columns: sampleColumns)
        XCTAssertEqual(sql, "SELECT COUNT(*) FROM data")
    }

    // MARK: - Single Filter

    func testSingleContainsFilter() {
        let state = ViewState(
            sortColumns: [],
            filters: [
                ColumnFilter(column: "name", operator: .contains, value: .string("john"))
            ],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 100
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM data WHERE \"name\" ILIKE '%john%' ESCAPE '\\' LIMIT 500 OFFSET 0")
    }

    func testSingleEqualsStringFilter() {
        let state = ViewState(
            sortColumns: [],
            filters: [
                ColumnFilter(column: "name", operator: .equals, value: .string("Alice"))
            ],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 1
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM data WHERE \"name\" = 'Alice' LIMIT 500 OFFSET 0")
    }

    func testSingleEqualsNumericFilter() {
        let state = ViewState(
            sortColumns: [],
            filters: [
                ColumnFilter(column: "age", operator: .equals, value: .number(25))
            ],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 10
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM data WHERE \"age\" = 25 LIMIT 500 OFFSET 0")
    }

    // MARK: - Multiple Filters (AND)

    func testMultipleFiltersAND() {
        let state = ViewState(
            sortColumns: [],
            filters: [
                ColumnFilter(column: "name", operator: .contains, value: .string("john")),
                ColumnFilter(column: "age", operator: .greaterThan, value: .number(30)),
            ],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 5
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM data WHERE \"name\" ILIKE '%john%' ESCAPE '\\' AND \"age\" > 30 LIMIT 500 OFFSET 0")
    }

    // MARK: - Global Search

    func testGlobalSearch() {
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: "test",
            visibleRange: 0..<500,
            totalFilteredRows: 50
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertTrue(sql.contains("WHERE"))
        XCTAssertTrue(sql.contains("CAST(\"name\" AS TEXT) ILIKE '%test%' ESCAPE '\\'"))
        XCTAssertTrue(sql.contains("CAST(\"age\" AS TEXT) ILIKE '%test%' ESCAPE '\\'"))
        XCTAssertTrue(sql.contains(" OR "))
    }

    func testGlobalSearchExcludesGridkaRowId() {
        let columnsWithRowId = sampleColumns! + [
            ColumnDescriptor(name: "_gridka_rowid", duckDBType: .bigint, displayType: .integer, index: 5)
        ]
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: "test",
            visibleRange: 0..<500,
            totalFilteredRows: 50
        )
        let sql = coordinator.buildQuery(for: state, columns: columnsWithRowId, range: 0..<500)
        XCTAssertFalse(sql.contains("_gridka_rowid"))
    }

    func testEmptySearchTermIgnored() {
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: "",
            visibleRange: 0..<500,
            totalFilteredRows: 1000
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM data LIMIT 500 OFFSET 0")
    }

    // MARK: - Sorting

    func testSingleSortAscending() {
        let state = ViewState(
            sortColumns: [SortColumn(column: "name", direction: .ascending)],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 1000
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM data ORDER BY \"name\" ASC NULLS LAST LIMIT 500 OFFSET 0")
    }

    func testSingleSortDescending() {
        let state = ViewState(
            sortColumns: [SortColumn(column: "age", direction: .descending)],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 1000
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM data ORDER BY \"age\" DESC NULLS LAST LIMIT 500 OFFSET 0")
    }

    func testMultiColumnSort() {
        let state = ViewState(
            sortColumns: [
                SortColumn(column: "name", direction: .ascending),
                SortColumn(column: "age", direction: .descending),
            ],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 1000
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM data ORDER BY \"name\" ASC NULLS LAST, \"age\" DESC NULLS LAST LIMIT 500 OFFSET 0")
    }

    // MARK: - Combined Filter + Sort + Search

    func testCombinedFilterSortSearch() {
        let state = ViewState(
            sortColumns: [SortColumn(column: "age", direction: .descending)],
            filters: [
                ColumnFilter(column: "active", operator: .isTrue, value: .none)
            ],
            searchTerm: "dev",
            visibleRange: 0..<500,
            totalFilteredRows: 10
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertTrue(sql.hasPrefix("SELECT * FROM data WHERE"))
        XCTAssertTrue(sql.contains("\"active\" = true"))
        XCTAssertTrue(sql.contains("ILIKE '%dev%'"))
        XCTAssertTrue(sql.contains("ORDER BY \"age\" DESC NULLS LAST"))
        XCTAssertTrue(sql.hasSuffix("LIMIT 500 OFFSET 0"))
    }

    func testCountQueryWithFilters() {
        let state = ViewState(
            sortColumns: [SortColumn(column: "age", direction: .ascending)],
            filters: [
                ColumnFilter(column: "name", operator: .contains, value: .string("test"))
            ],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 10
        )
        let sql = coordinator.buildCountQuery(for: state, columns: sampleColumns)
        XCTAssertEqual(sql, "SELECT COUNT(*) FROM data WHERE \"name\" ILIKE '%test%' ESCAPE '\\'")
        // Count query should NOT include ORDER BY
        XCTAssertFalse(sql.contains("ORDER BY"))
    }

    // MARK: - All Filter Operator Types

    func testContainsOperator() {
        let filter = ColumnFilter(column: "name", operator: .contains, value: .string("alice"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"name\" ILIKE '%alice%' ESCAPE '\\'"))
    }

    func testEqualsStringOperator() {
        let filter = ColumnFilter(column: "name", operator: .equals, value: .string("Alice"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"name\" = 'Alice'"))
    }

    func testEqualsNumericOperator() {
        let filter = ColumnFilter(column: "age", operator: .equals, value: .number(42))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"age\" = 42"))
    }

    func testStartsWithOperator() {
        let filter = ColumnFilter(column: "name", operator: .startsWith, value: .string("Al"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"name\" ILIKE 'Al%' ESCAPE '\\'"))
    }

    func testEndsWithOperator() {
        let filter = ColumnFilter(column: "name", operator: .endsWith, value: .string("son"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"name\" ILIKE '%son' ESCAPE '\\'"))
    }

    func testRegexOperator() {
        let filter = ColumnFilter(column: "name", operator: .regex, value: .string("^[A-Z]"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"name\" ~ '^[A-Z]'"))
    }

    func testIsEmptyOperator() {
        let filter = ColumnFilter(column: "name", operator: .isEmpty, value: .none)
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("(\"name\" = '' OR \"name\" IS NULL)"))
    }

    func testIsNotEmptyOperator() {
        let filter = ColumnFilter(column: "name", operator: .isNotEmpty, value: .none)
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("(\"name\" <> '' AND \"name\" IS NOT NULL)"))
    }

    func testGreaterThanOperator() {
        let filter = ColumnFilter(column: "age", operator: .greaterThan, value: .number(25))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"age\" > 25"))
    }

    func testLessThanOperator() {
        let filter = ColumnFilter(column: "age", operator: .lessThan, value: .number(65))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"age\" < 65"))
    }

    func testGreaterOrEqualOperator() {
        let filter = ColumnFilter(column: "salary", operator: .greaterOrEqual, value: .number(50000))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"salary\" >= 50000"))
    }

    func testLessOrEqualOperator() {
        let filter = ColumnFilter(column: "salary", operator: .lessOrEqual, value: .number(100000))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"salary\" <= 100000"))
    }

    func testBetweenOperator() {
        let filter = ColumnFilter(column: "hired", operator: .between, value: .dateRange("2020-01-01", "2023-12-31"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"hired\" BETWEEN '2020-01-01' AND '2023-12-31'"))
    }

    func testIsNullOperator() {
        let filter = ColumnFilter(column: "name", operator: .isNull, value: .none)
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"name\" IS NULL"))
    }

    func testIsNotNullOperator() {
        let filter = ColumnFilter(column: "name", operator: .isNotNull, value: .none)
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"name\" IS NOT NULL"))
    }

    func testIsTrueOperator() {
        let filter = ColumnFilter(column: "active", operator: .isTrue, value: .none)
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"active\" = true"))
    }

    func testIsFalseOperator() {
        let filter = ColumnFilter(column: "active", operator: .isFalse, value: .none)
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"active\" = false"))
    }

    // MARK: - Date Filter Operators

    func testDateGreaterThan() {
        let filter = ColumnFilter(column: "hired", operator: .greaterThan, value: .string("2023-01-01"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"hired\" > '2023-01-01'"))
    }

    func testDateLessThan() {
        let filter = ColumnFilter(column: "hired", operator: .lessThan, value: .string("2023-12-31"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"hired\" < '2023-12-31'"))
    }

    func testDateGreaterOrEqual() {
        let filter = ColumnFilter(column: "hired", operator: .greaterOrEqual, value: .string("2020-06-15"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"hired\" >= '2020-06-15'"))
    }

    func testDateLessOrEqual() {
        let filter = ColumnFilter(column: "hired", operator: .lessOrEqual, value: .string("2024-01-01"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"hired\" <= '2024-01-01'"))
    }

    func testDateBetween() {
        let filter = ColumnFilter(column: "hired", operator: .between, value: .dateRange("2020-01-01", "2024-12-31"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"hired\" BETWEEN '2020-01-01' AND '2024-12-31'"))
    }

    func testNumericBetween() {
        let filter = ColumnFilter(column: "age", operator: .between, value: .dateRange("18", "65"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("\"age\" BETWEEN '18' AND '65'"))
    }

    // MARK: - SQL Injection Prevention

    func testDateFilterEscapesSingleQuotes() {
        let filter = ColumnFilter(column: "hired", operator: .greaterThan, value: .string("2023'; DROP TABLE data; --"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("2023''; DROP TABLE data; --"))
        XCTAssertFalse(sql.contains("2023'; DROP"))
    }

    func testBetweenEscapesSingleQuotes() {
        let filter = ColumnFilter(column: "hired", operator: .between, value: .dateRange("2020' OR 1=1 --", "2024-12-31"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("2020'' OR 1=1 --"))
    }

    func testEqualsStringEscapesSingleQuotes() {
        let filter = ColumnFilter(column: "name", operator: .equals, value: .string("O'Malley"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("'O''Malley'"))
    }

    func testRegexEscapesSingleQuotes() {
        let filter = ColumnFilter(column: "name", operator: .regex, value: .string("test'pattern"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("'test''pattern'"))
    }

    // MARK: - Multiple Filters Combined

    func testThreeFiltersAND() {
        let state = ViewState(
            sortColumns: [],
            filters: [
                ColumnFilter(column: "name", operator: .contains, value: .string("john")),
                ColumnFilter(column: "age", operator: .greaterThan, value: .number(25)),
                ColumnFilter(column: "active", operator: .isTrue, value: .none),
            ],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 3
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertTrue(sql.contains("\"name\" ILIKE '%john%' ESCAPE '\\'"))
        XCTAssertTrue(sql.contains("\"age\" > 25"))
        XCTAssertTrue(sql.contains("\"active\" = true"))
        // All conditions joined with AND
        let whereClause = sql.components(separatedBy: "WHERE ").last!.components(separatedBy: " LIMIT").first!
        let andCount = whereClause.components(separatedBy: " AND ").count
        XCTAssertEqual(andCount, 3)
    }

    func testFilterWithSearchCombined() {
        let state = ViewState(
            sortColumns: [],
            filters: [
                ColumnFilter(column: "age", operator: .greaterOrEqual, value: .number(21))
            ],
            searchTerm: "smith",
            visibleRange: 0..<500,
            totalFilteredRows: 5
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        // Filter and search both present
        XCTAssertTrue(sql.contains("\"age\" >= 21"))
        XCTAssertTrue(sql.contains("ILIKE '%smith%'"))
        // Filter AND search condition (search is wrapped in parentheses)
        XCTAssertTrue(sql.contains(" AND ("))
    }

    func testInvalidFilterValueReturnsNoCondition() {
        // greaterThan with boolean value should be ignored
        let filter = ColumnFilter(column: "age", operator: .greaterThan, value: .boolean(true))
        let sql = buildQueryWithFilter(filter)
        // No WHERE clause since the filter was invalid
        XCTAssertEqual(sql, "SELECT * FROM data LIMIT 500 OFFSET 0")
    }

    // MARK: - SQL Escaping

    func testQuoteIdentifier() {
        XCTAssertEqual(QueryCoordinator.quote("name"), "\"name\"")
        XCTAssertEqual(QueryCoordinator.quote("my column"), "\"my column\"")
        XCTAssertEqual(QueryCoordinator.quote("col\"name"), "\"col\"\"name\"")
    }

    func testEscapeValue() {
        XCTAssertEqual(QueryCoordinator.escape("hello"), "hello")
        XCTAssertEqual(QueryCoordinator.escape("it's"), "it''s")
        XCTAssertEqual(QueryCoordinator.escape("100%"), "100\\%")
        XCTAssertEqual(QueryCoordinator.escape("under_score"), "under\\_score")
        XCTAssertEqual(QueryCoordinator.escape("back\\slash"), "back\\\\slash")
    }

    func testContainsFilterEscapesSpecialChars() {
        let filter = ColumnFilter(column: "name", operator: .contains, value: .string("O'Brien"))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("O''Brien"))
    }

    func testSearchEscapesSpecialChars() {
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: "100%",
            visibleRange: 0..<500,
            totalFilteredRows: 50
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertTrue(sql.contains("100\\%"))
    }

    // MARK: - Numeric Formatting

    func testWholeNumberFormattedAsInteger() {
        let filter = ColumnFilter(column: "age", operator: .greaterThan, value: .number(25.0))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("> 25"))
        XCTAssertFalse(sql.contains("> 25.0"))
    }

    func testDecimalNumberPreserved() {
        let filter = ColumnFilter(column: "salary", operator: .greaterThan, value: .number(50000.75))
        let sql = buildQueryWithFilter(filter)
        XCTAssertTrue(sql.contains("> 50000.75"))
    }

    // MARK: - Helpers

    private func buildQueryWithFilter(_ filter: ColumnFilter) -> String {
        let state = ViewState(
            sortColumns: [],
            filters: [filter],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 100
        )
        return coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
    }

    // MARK: - Computed Columns (US-019)

    func testComputedColumnInSelect() {
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 1000,
            computedColumns: [ComputedColumn(name: "full_name", expression: "CONCAT(name, ' ', name)")]
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM (SELECT *, (CONCAT(name, ' ', name)) AS \"full_name\" FROM data) LIMIT 500 OFFSET 0")
    }

    func testMultipleComputedColumns() {
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 1000,
            computedColumns: [
                ComputedColumn(name: "double_age", expression: "age * 2"),
                ComputedColumn(name: "name_upper", expression: "UPPER(name)"),
            ]
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM (SELECT *, (age * 2) AS \"double_age\", (UPPER(name)) AS \"name_upper\" FROM data) LIMIT 500 OFFSET 0")
    }

    func testComputedColumnCountQuery() {
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 1000,
            computedColumns: [ComputedColumn(name: "calc", expression: "age + 1")]
        )
        let sql = coordinator.buildCountQuery(for: state, columns: sampleColumns)
        XCTAssertEqual(sql, "SELECT COUNT(*) FROM (SELECT *, (age + 1) AS \"calc\" FROM data)")
    }

    func testComputedColumnWithFilterAndSort() {
        let state = ViewState(
            sortColumns: [SortColumn(column: "double_age", direction: .descending)],
            filters: [ColumnFilter(column: "double_age", operator: .greaterThan, value: .number(50))],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 100,
            computedColumns: [ComputedColumn(name: "double_age", expression: "age * 2")]
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM (SELECT *, (age * 2) AS \"double_age\" FROM data) WHERE \"double_age\" > 50 ORDER BY \"double_age\" DESC NULLS LAST LIMIT 500 OFFSET 0")
    }

    func testNoComputedColumnsUsesPlainData() {
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: nil,
            visibleRange: 0..<500,
            totalFilteredRows: 1000,
            computedColumns: []
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        XCTAssertEqual(sql, "SELECT * FROM data LIMIT 500 OFFSET 0")
    }

    func testComputedColumnInSearch() {
        let state = ViewState(
            sortColumns: [],
            filters: [],
            searchTerm: "hello",
            visibleRange: 0..<500,
            totalFilteredRows: 100,
            computedColumns: [ComputedColumn(name: "greeting", expression: "CONCAT('Hello ', name)")]
        )
        let sql = coordinator.buildQuery(for: state, columns: sampleColumns, range: 0..<500)
        // Search should include both base columns and computed columns
        XCTAssert(sql.contains("CAST(\"greeting\" AS TEXT) ILIKE '%hello%'"), "Search should include computed column")
        XCTAssert(sql.contains("CAST(\"name\" AS TEXT) ILIKE '%hello%'"), "Search should include base columns")
    }

    func testBuildWhereSQLIncludesComputedFiltersAndSearch() {
        let state = ViewState(
            sortColumns: [],
            filters: [
                ColumnFilter(column: "name", operator: .contains, value: .string("alice")),
                ColumnFilter(column: "double_age", operator: .greaterThan, value: .number(50)),
            ],
            searchTerm: "test",
            visibleRange: 0..<500,
            totalFilteredRows: 100,
            computedColumns: [ComputedColumn(name: "double_age", expression: "age * 2")]
        )
        let whereSQL = coordinator.buildWhereSQL(for: state, columns: sampleColumns)
        // Base column filter should be included
        XCTAssert(whereSQL.contains("\"name\" ILIKE"), "Base column filter should be present")
        // Computed column filter should be included (profiler now uses source subquery)
        XCTAssert(whereSQL.contains("\"double_age\" > 50"), "Computed column filter should be present")
        // Computed column should appear in search
        XCTAssert(whereSQL.contains("CAST(\"double_age\" AS TEXT) ILIKE '%test%'"), "Computed column should be in search")
        // Base column search should still work
        XCTAssert(whereSQL.contains("CAST(\"name\" AS TEXT) ILIKE '%test%'"), "Base column search should be present")
    }
}
