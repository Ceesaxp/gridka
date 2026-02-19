import Foundation

// MARK: - DateFormatStyle

enum DateFormatStyle: String, CaseIterable {
    case ymd = "yyyy-MM-dd"
    case dmy = "dd/MM/yyyy"
    case mdy = "MM/dd/yyyy"

    var displayName: String {
        switch self {
        case .ymd: return "YYYY-MM-DD"
        case .dmy: return "DD/MM/YYYY"
        case .mdy: return "MM/DD/YYYY"
        }
    }
}

// MARK: - SettingsManager

final class SettingsManager {

    static let shared = SettingsManager()

    static let settingsChangedNotification = Notification.Name("GridkaSettingsChanged")

    private enum Keys {
        static let dateFormat = "GridkaDateFormat"
        static let thousandsSeparator = "GridkaThousandsSeparator"
        static let decimalComma = "GridkaDecimalComma"
    }

    private init() {}

    var dateFormat: DateFormatStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.dateFormat),
                  let style = DateFormatStyle(rawValue: raw) else {
                return .ymd
            }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.dateFormat)
            notifyChange()
        }
    }

    var useThousandsSeparator: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.thousandsSeparator) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.thousandsSeparator)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.thousandsSeparator)
            // Mutually exclusive: comma thousands separator conflicts with decimal comma
            if newValue && useDecimalComma {
                UserDefaults.standard.set(false, forKey: Keys.decimalComma)
            }
            notifyChange()
        }
    }

    var useDecimalComma: Bool {
        get {
            return UserDefaults.standard.bool(forKey: Keys.decimalComma)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.decimalComma)
            // Mutually exclusive: decimal comma conflicts with comma thousands separator
            if newValue && useThousandsSeparator {
                UserDefaults.standard.set(false, forKey: Keys.thousandsSeparator)
            }
            notifyChange()
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: SettingsManager.settingsChangedNotification, object: nil)
    }
}
