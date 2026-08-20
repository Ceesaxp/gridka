import Foundation

enum HTTPURLParser {
    static let maximumClickableURLLength = 8_192

    static func parse(_ value: String, allowUserInfo: Bool = false) -> URL? {
        guard hasHTTPSchemePrefix(value),
              value.utf8.prefix(maximumClickableURLLength + 1).count <= maximumClickableURLLength,
              let url = URL(string: value, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              allowUserInfo || (url.user == nil && url.password == nil) else {
            return nil
        }

        return url
    }

    private static func hasHTTPSchemePrefix(_ value: String) -> Bool {
        return value.prefix(7).compare("http://", options: .caseInsensitive) == .orderedSame
            || value.prefix(8).compare("https://", options: .caseInsensitive) == .orderedSame
    }
}
