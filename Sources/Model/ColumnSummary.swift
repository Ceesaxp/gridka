import Foundation

/// Lightweight summary data for a single column, computed once on file load.
/// Used by sparklines in column headers (US-015) for instant rendering without per-column queries.
struct ColumnSummary {
    let columnName: String
    let detectedType: DisplayType
    let cardinality: Int        // COUNT(DISTINCT col)
    let nullCount: Int          // COUNT(*) - COUNT(col)
    let totalRows: Int          // COUNT(*)
    let distribution: Distribution

    /// Percentage of non-null values (0.0–1.0).
    var completeness: Double {
        guard totalRows > 0 else { return 0 }
        return Double(totalRows - nullCount) / Double(totalRows)
    }
}

/// Distribution data for sparkline rendering. Determined by column type and cardinality.
enum Distribution {
    /// Numeric columns: equal-width histogram buckets.
    case histogram(buckets: [(range: String, count: Int)])

    /// Low-cardinality categorical columns (≤15 unique): top values by frequency.
    case frequency(values: [(value: String, count: Int)])

    /// Boolean columns: true/false counts.
    case boolean(trueCount: Int, falseCount: Int)

    /// High-cardinality text columns (>15 unique): just the unique count (no chart data).
    case highCardinality(uniqueCount: Int)
}
