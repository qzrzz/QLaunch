import Foundation

enum LaunchpadBackgroundMode: String, CaseIterable, Identifiable {
    case wallpaper
    case screen
    case custom

    static let defaultMode: Self = .wallpaper

    var id: Self { self }

    var title: String {
        L10n.tr("background.mode.\(rawValue).title")
    }

    var detail: String {
        L10n.tr("background.mode.\(rawValue).detail")
    }
}

enum LaunchpadBackgroundPreferences {
    static let modeKey = "launchpadBackgroundMode"
    static let customImagePathKey = "launchpadBackgroundCustomImagePath"
    static let blurAmountKey = "launchpadBackgroundBlurAmount"
    static let defaultBlurAmount: Double = 44
    static let minimumBlurAmount: Double = 0
    static let maximumBlurAmount: Double = 100

    static var mode: LaunchpadBackgroundMode {
        guard let rawValue = UserDefaults.standard.string(forKey: modeKey),
              let mode = LaunchpadBackgroundMode(rawValue: rawValue) else {
            return .defaultMode
        }
        return mode
    }

    static var customImageURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: customImagePathKey),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    static var blurAmount: CGFloat {
        let stored = UserDefaults.standard.double(forKey: blurAmountKey)
        let value = UserDefaults.standard.object(forKey: blurAmountKey) == nil
            ? defaultBlurAmount
            : stored
        return CGFloat(min(max(value, minimumBlurAmount), maximumBlurAmount))
    }

}
