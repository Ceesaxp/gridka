import Foundation

final class QueryCoordinator {

    // MARK: - Public Query Builders

    func buildQuery(for state: ViewState, columns: [ColumnDescriptor], range: Range<Int>) -> String {
        let source = buildSourceExpression(for: state)
        var parts = ["SELECT * FROM \(source)"]

        let whereClause = buildWhereClause(for: state, columns: columns)
        if !whereClause.isEmpty {
            parts.append("WHERE \(whereClause)")
        }

        let orderClause = buildOrderClause(for: state)
        if !orderClause.isEmpty {
            parts.append("ORDER BY \(orderClause)")
        }

        let limit = range.count
        let offset = range.lowerBound
        parts.append("LIMIT \(limit) OFFSET \(offset)")

        return parts.joined(separator: " ")
    }

    func buildCountQuery(for state: ViewState, columns: [ColumnDescriptor]) -> String {
        let source = buildSourceExpression(for: state)
        var parts = ["SELECT COUNT(*) FROM \(source)"]

        let whereClause = buildWhereClause(for: state, columns: columns)
        if !whereClause.isEmpty {
            parts.append("WHERE \(whereClause)")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Static Helpers

    static func quote(_ identifier: String) -> String {
        let escaped = identifier.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    static func escape(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "'", with: "''")
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "%", with: "\\%")
        result = result.replacingOccurrences(of: "_", with: "\\_")
        return result
    }

    /// Builds just the WHERE clause (without the "WHERE" keyword) from the current ViewState.
    /// Returns an empty string if no conditions apply. Used by ProfilerQueryBuilder to include
    /// the same filter/search conditions in profiler queries.
    func buildWhereSQL(for state: ViewState, columns: [ColumnDescriptor]) -> String {
        return buildWhereClause(for: state, columns: columns)
    }

    // MARK: - Private Builders

    /// Returns the FROM source: plain "data" when no computed columns exist,
    /// or a subquery "(SELECT *, (expr) AS name, ... FROM data)" when they do.
    private func buildSourceExpression(for state: ViewState) -> String {
        guard !state.computedColumns.isEmpty else { return "data" }
        let computedParts = state.computedColumns.map { cc in
            "(\(cc.expression)) AS \(QueryCoordinator.quote(cc.name))"
        }
        return "(SELECT *, \(computedParts.joined(separator: ", ")) FROM data)"
    }

    private func buildWhereClause(for state: ViewState, columns: [ColumnDescriptor]) -> String {
        var conditions: [String] = []

        for filter in state.filters {
            if let sql = buildFilterCondition(filter) {
                conditions.append(sql)
            }
        }

        if let searchTerm = state.searchTerm, !searchTerm.isEmpty {
            let searchCondition = buildSearchCondition(searchTerm, columns: columns, computedColumns: state.computedColumns)
            if !searchCondition.isEmpty {
                conditions.append("(\(searchCondition))")
            }
        }

        return conditions.joined(separator: " AND ")
    }

    private func buildFilterCondition(_ filter: ColumnFilter) -> String? {
        guard let condition = buildFilterSQL(filter) else { return nil }
        if filter.negate {
            return "NOT (\(condition))"
        }
        return condition
    }

    private func buildFilterSQL(_ filter: ColumnFilter) -> String? {
        let col = QueryCoordinator.quote(filter.column)

        switch filter.operator {
        // Text operators
        case .contains:
            guard case .string(let val) = filter.value else { return nil }
            return "\(col) ILIKE '%\(QueryCoordinator.escape(val))%' ESCAPE '\\'"

        case .equals:
            switch filter.value {
            case .string(let val):
                return "\(col) = '\(val.replacingOccurrences(of: "'", with: "''"))'"
            case .number(let val):
                return "\(col) = \(formatNumber(val))"
            default:
                return nil
            }

        case .startsWith:
            guard case .string(let val) = filter.value else { return nil }
            return "\(col) ILIKE '\(QueryCoordinator.escape(val))%' ESCAPE '\\'"

        case .endsWith:
            guard case .string(let val) = filter.value else { return nil }
            return "\(col) ILIKE '%\(QueryCoordinator.escape(val))' ESCAPE '\\'"

        case .regex:
            guard case .string(let val) = filter.value else { return nil }
            return "\(col) ~ '\(val.replacingOccurrences(of: "'", with: "''"))'"

        case .isEmpty:
            return "(\(col) = '' OR \(col) IS NULL)"

        case .isNotEmpty:
            return "(\(col) <> '' AND \(col) IS NOT NULL)"

        // Comparison operators (numeric and date)
        case .greaterThan:
            switch filter.value {
            case .number(let val):
                return "\(col) > \(formatNumber(val))"
            case .string(let val):
                return "\(col) > '\(val.replacingOccurrences(of: "'", with: "''"))'"
            default:
                return nil
            }

        case .lessThan:
            switch filter.value {
            case .number(let val):
                return "\(col) < \(formatNumber(val))"
            case .string(let val):
                return "\(col) < '\(val.replacingOccurrences(of: "'", with: "''"))'"
            default:
                return nil
            }

        case .greaterOrEqual:
            switch filter.value {
            case .number(let val):
                return "\(col) >= \(formatNumber(val))"
            case .string(let val):
                return "\(col) >= '\(val.replacingOccurrences(of: "'", with: "''"))'"
            default:
                return nil
            }

        case .lessOrEqual:
            switch filter.value {
            case .number(let val):
                return "\(col) <= \(formatNumber(val))"
            case .string(let val):
                return "\(col) <= '\(val.replacingOccurrences(of: "'", with: "''"))'"
            default:
                return nil
            }

        case .between:
            guard case .dateRange(let low, let high) = filter.value else {
                return nil
            }
            return "\(col) BETWEEN '\(low.replacingOccurrences(of: "'", with: "''"))' AND '\(high.replacingOccurrences(of: "'", with: "''"))'"

        // Null operators
        case .isNull:
            return "\(col) IS NULL"

        case .isNotNull:
            return "\(col) IS NOT NULL"

        // Boolean operators
        case .isTrue:
            return "\(col) = true"

        case .isFalse:
            return "\(col) = false"
        }
    }

    private func buildSearchCondition(_ searchTerm: String, columns: [ColumnDescriptor], computedColumns: [ComputedColumn] = []) -> String {
        let escapedTerm = QueryCoordinator.escape(searchTerm)
        var conditions = columns
            .filter { $0.name != "_gridka_rowid" }
            .map { "CAST(\(QueryCoordinator.quote($0.name)) AS TEXT) ILIKE '%\(escapedTerm)%' ESCAPE '\\'" }
        // Include computed columns in global search
        for cc in computedColumns {
            conditions.append("CAST(\(QueryCoordinator.quote(cc.name)) AS TEXT) ILIKE '%\(escapedTerm)%' ESCAPE '\\'")
        }
        return conditions.joined(separator: " OR ")
    }

    private func buildOrderClause(for state: ViewState) -> String {
        let parts = state.sortColumns.map { sortCol -> String in
            let dir = sortCol.direction == .ascending ? "ASC" : "DESC"
            return "\(QueryCoordinator.quote(sortCol.column)) \(dir) NULLS LAST"
        }
        return parts.joined(separator: ", ")
    }

    private func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && !value.isInfinite && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}
