import Foundation

/// Generates DuckDB SQL queries for the column profiler sidebar.
/// All queries respect the current ViewState filters/search so the profiler reflects filtered data.
final class ProfilerQueryBuilder {

    private let queryCoordinator = QueryCoordinator()

    /// Builds the overview stats query for a column: row count, unique count, null count, empty count.
    /// Returns a single-row result with 4 columns: total_rows, unique_count, null_count, empty_count.
    func buildOverviewQuery(columnName: String, viewState: ViewState, columns: [ColumnDescriptor]) -> String {
        let col = QueryCoordinator.quote(columnName)
        let whereClause = queryCoordinator.buildWhereSQL(for: viewState, columns: columns)
        let whereSQL = whereClause.isEmpty ? "" : " WHERE \(whereClause)"

        return """
        SELECT \
        COUNT(*) AS total_rows, \
        COUNT(DISTINCT \(col)) AS unique_count, \
        COUNT(*) - COUNT(\(col)) AS null_count, \
        SUM(CASE WHEN CAST(\(col) AS VARCHAR) = '' THEN 1 ELSE 0 END) AS empty_count \
        FROM data\(whereSQL)
        """
    }
}
