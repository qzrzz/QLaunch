import Combine
import Foundation
import QLaunchpadCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    var localeIdentifier: String {
        switch self {
        case .system:
            return Self.systemLanguage.localeIdentifier
        case .zhHans, .english, .japanese, .korean:
            return rawValue
        }
    }

    var displayName: String {
        switch self {
        case .system: L10n.tr("language.system")
        case .zhHans: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }

    static var systemLanguage: AppLanguage {
        for identifier in Locale.preferredLanguages {
            let normalized = identifier.lowercased()
            if normalized.hasPrefix("zh") { return .zhHans }
            if normalized.hasPrefix("ja") { return .japanese }
            if normalized.hasPrefix("ko") { return .korean }
            if normalized.hasPrefix("en") { return .english }
        }
        return .english
    }
}

extension Notification.Name {
    static let qlaunchpadLanguageChanged = Notification.Name("QLaunchpadLanguageChanged")
}

final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    static let defaultsKey = "appLanguage"

    @Published var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set(selection.rawValue, forKey: Self.defaultsKey)
            revision &+= 1
            NotificationCenter.default.post(name: .qlaunchpadLanguageChanged, object: nil)
        }
    }

    @Published private(set) var revision: UInt = 0
    private var localeObserver: NSObjectProtocol?

    var effectiveLanguage: AppLanguage {
        selection == .system ? .systemLanguage : selection
    }

    var locale: Locale {
        Locale(identifier: effectiveLanguage.localeIdentifier)
    }

    private init() {
        selection = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.selection == .system else { return }
            self.revision &+= 1
            NotificationCenter.default.post(name: .qlaunchpadLanguageChanged, object: nil)
        }
    }

    deinit {
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
        }
    }
}

enum L10n {
    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let language = LocalizationManager.shared.effectiveLanguage
        // Never use SwiftPM `Bundle.module` here: its generated accessor
        // traps when the resource bundle is not next to the `.app`.
        let stringsBundle = QLaunchpadResources.bundle ?? .main
        let resourceBundle: Bundle
        if let stringsPath = stringsBundle.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: nil,
            forLocalization: language.localeIdentifier
        ),
           let bundle = Bundle(path: (stringsPath as NSString).deletingLastPathComponent) {
            resourceBundle = bundle
        } else {
            resourceBundle = stringsBundle
        }

        let format = NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: resourceBundle,
            value: key,
            comment: ""
        )
        guard !arguments.isEmpty else { return format }
        return String(
            format: format,
            locale: Locale(identifier: language.localeIdentifier),
            arguments: arguments
        )
    }

    static func profileError(_ error: LaunchpadLayoutProfileError) -> String {
        switch error {
        case .invalidProfileID: tr("error.profile.invalid")
        case .defaultProfileProtected: tr("error.profile.defaultProtected")
        case .profileNotFound: tr("error.profile.notFound")
        case .emptyName: tr("error.profile.emptyName")
        case .missingDocument: tr("error.profile.missingDocument")
        }
    }
}

extension LaunchpadAutoLayoutKind {
    var localizedTitle: String {
        L10n.tr("layout.auto.\(rawValue)")
    }

    var localizedSortingPhrase: String {
        L10n.tr("layout.auto.phrase.\(rawValue)")
    }

    var localizedDragHintMessage: String {
        L10n.tr("layout.auto.dragHint", localizedSortingPhrase)
    }
}
