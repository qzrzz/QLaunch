import Foundation

/// QLaunch-only naming; the original bundle name remains available for search and reset.
public struct AppName: Hashable, Sendable {
    public let original: String
    public let custom: String?
    public let originalPinyin: PinyinSearchMetadata
    public let pinyin: PinyinSearchMetadata

    public var display: String { custom ?? original }

    public init(original: String, custom: String? = nil, originalPinyin: PinyinSearchMetadata? = nil) {
        self.original = original
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.custom = trimmed.isEmpty || trimmed == original ? nil : trimmed
        self.originalPinyin = originalPinyin ?? .make(for: original)
        self.pinyin = self.custom.map { .make(for: $0) } ?? self.originalPinyin
    }
}
