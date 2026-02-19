import Foundation
import Quartz
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        // Read only the first 256 KB for preview
        let previewLimit = 256 * 1024
        let previewData = data.count > previewLimit ? data.prefix(previewLimit) : data
        let csvString = String(decoding: previewData, as: UTF8.self)
        let truncated = data.count > previewLimit

        let html = renderCSVAsHTML(csvString, maxRows: 200, truncatedFile: truncated)

        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in
            return html.data(using: .utf8)!
        }
    }

    // MARK: - HTML Rendering

    private func renderCSVAsHTML(_ csv: String, maxRows: Int, truncatedFile: Bool) -> String {
        let lines = csv.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return "<html><body style='font-family:-apple-system;color:#888;padding:40px;text-align:center'>Empty file</body></html>"
        }

        let separator = detectSeparator(lines[0])
        let headers = parseCSVLine(lines[0], separator: separator)

        var html = """
        <html>
        <head>
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 12px;
                margin: 0;
                padding: 0;
                background: white;
                color: #1d1d1f;
            }
            table {
                border-collapse: collapse;
                width: 100%;
            }
            th {
                background: #f5f5f7;
                font-weight: 600;
                text-align: left;
                position: sticky;
                top: 0;
                border-bottom: 2px solid #d2d2d7;
                z-index: 1;
            }
            th, td {
                padding: 3px 8px;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                max-width: 300px;
                border-bottom: 1px solid #e5e5e5;
            }
            tr:hover { background: #f0f0f5; }
            .info {
                color: #86868b;
                font-size: 11px;
                padding: 6px 8px;
                border-top: 1px solid #d2d2d7;
                background: #f5f5f7;
                position: sticky;
                bottom: 0;
            }
            @media (prefers-color-scheme: dark) {
                body { background: #1e1e1e; color: #e5e5e5; }
                th { background: #2a2a2a; border-bottom-color: #444; }
                td { border-bottom-color: #333; }
                tr:hover { background: #2a2a2e; }
                .info { background: #2a2a2a; border-top-color: #444; color: #98989d; }
            }
        </style>
        </head>
        <body>
        <table>
        <tr>
        """

        for h in headers {
            html += "<th>\(escapeHTML(h))</th>"
        }
        html += "</tr>\n"

        let rowCount = min(lines.count, maxRows + 1)
        for i in 1..<rowCount {
            let fields = parseCSVLine(lines[i], separator: separator)
            html += "<tr>"
            for f in fields {
                html += "<td>\(escapeHTML(f))</td>"
            }
            html += "</tr>\n"
        }

        html += "</table>"

        let shownRows = rowCount - 1
        var infoText = "\(shownRows) rows \u{00d7} \(headers.count) columns"
        if truncatedFile || lines.count > maxRows + 1 {
            infoText += " (preview)"
        }
        html += "<div class='info'>\(infoText)</div>"

        html += "</body></html>"
        return html
    }

    // MARK: - CSV Parsing

    private func detectSeparator(_ line: String) -> Character {
        let tabCount = line.filter { $0 == "\t" }.count
        let commaCount = line.filter { $0 == "," }.count
        let semiCount = line.filter { $0 == ";" }.count
        if tabCount > commaCount && tabCount > semiCount { return "\t" }
        if semiCount > commaCount { return ";" }
        return ","
    }

    private func parseCSVLine(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex

        while i < line.endIndex {
            let ch = line[i]

            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex && line[next] == "\"" {
                        current.append("\"")
                        i = line.index(after: next)
                    } else {
                        inQuotes = false
                        i = line.index(after: i)
                    }
                } else {
                    current.append(ch)
                    i = line.index(after: i)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                    i = line.index(after: i)
                } else if ch == separator {
                    fields.append(current)
                    current = ""
                    i = line.index(after: i)
                } else {
                    current.append(ch)
                    i = line.index(after: i)
                }
            }
        }
        fields.append(current)
        return fields
    }

    private func escapeHTML(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
