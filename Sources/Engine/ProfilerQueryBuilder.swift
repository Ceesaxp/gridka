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

    // MARK: - Distribution Queries

    /// Builds a histogram query for numeric columns using WIDTH_BUCKET.
    /// Returns rows with: bucket_label (VARCHAR), cnt (BIGINT), and a first row with min/max metadata.
    /// The first query gets min/max, then we use WIDTH_BUCKET to create equal-width bins.
    func buildNumericHistogramQuery(
        columnName: String,
        viewState: ViewState,
        columns: [ColumnDescriptor],
        bucketCount: Int = 10
    ) -> String {
        let col = QueryCoordinator.quote(columnName)
        let whereClause = queryCoordinator.buildWhereSQL(for: viewState, columns: columns)
        let filterSQL = whereClause.isEmpty ? "" : " AND \(whereClause)"
        let whereSQL = whereClause.isEmpty ? "" : " WHERE \(whereClause)"

        // Use a CTE to compute min/max, then WIDTH_BUCKET for binning.
        // DuckDB's WIDTH_BUCKET(value, min, max, count) returns bucket 0 for < min,
        // count+1 for >= max. We clamp to 1..count range.
        return """
        WITH bounds AS ( \
        SELECT MIN(\(col)) AS col_min, MAX(\(col)) AS col_max \
        FROM data WHERE \(col) IS NOT NULL\(filterSQL) \
        ), \
        bucketed AS ( \
        SELECT \
        CASE WHEN bounds.col_min = bounds.col_max THEN 1 \
        ELSE LEAST(\(bucketCount), GREATEST(1, \
        WIDTH_BUCKET(\(col)::DOUBLE, bounds.col_min::DOUBLE, bounds.col_max::DOUBLE + 1e-9, \(bucketCount)) \
        )) END AS bucket, \
        bounds.col_min, bounds.col_max \
        FROM data, bounds \
        WHERE \(col) IS NOT NULL\(filterSQL) \
        ) \
        SELECT \
        bucket, \
        COUNT(*) AS cnt, \
        MIN(col_min) AS col_min, \
        MIN(col_max) AS col_max \
        FROM bucketed \
        GROUP BY bucket \
        ORDER BY bucket
        """
    }

    /// Builds a frequency query for categorical columns (top N values by count).
    func buildCategoricalFrequencyQuery(
        columnName: String,
        viewState: ViewState,
        columns: [ColumnDescriptor],
        limit: Int = 10
    ) -> String {
        let col = QueryCoordinator.quote(columnName)
        let whereClause = queryCoordinator.buildWhereSQL(for: viewState, columns: columns)
        let filterSQL = whereClause.isEmpty ? "" : " AND \(whereClause)"

        return """
        SELECT CAST(\(col) AS VARCHAR) AS val, COUNT(*) AS cnt \
        FROM data \
        WHERE \(col) IS NOT NULL\(filterSQL) \
        GROUP BY \(col) \
        ORDER BY cnt DESC \
        LIMIT \(limit)
        """
    }

    /// Builds a boolean distribution query returning true/false counts.
    func buildBooleanDistributionQuery(
        columnName: String,
        viewState: ViewState,
        columns: [ColumnDescriptor]
    ) -> String {
        let col = QueryCoordinator.quote(columnName)
        let whereClause = queryCoordinator.buildWhereSQL(for: viewState, columns: columns)
        let whereSQL = whereClause.isEmpty ? "" : " WHERE \(whereClause)"

        return """
        SELECT \
        SUM(CASE WHEN \(col) = true THEN 1 ELSE 0 END) AS true_count, \
        SUM(CASE WHEN \(col) = false THEN 1 ELSE 0 END) AS false_count \
        FROM data\(whereSQL)
        """
    }
}
