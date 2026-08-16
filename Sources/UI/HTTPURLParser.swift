import Foundation

enum HTTPURLParser {
    static func parse(_ value: String) -> URL? {
        guard hasHTTPSchemePrefix(value),
              let url = URL(string: value, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }

        return url
    }

    private static func hasHTTPSchemePrefix(_ value: String) -> Bool {
        return value.prefix(7).compare("http://", options: .caseInsensitive) == .orderedSame
            || value.prefix(8).compare("https://", options: .caseInsensitive) == .orderedSame
    }
}
