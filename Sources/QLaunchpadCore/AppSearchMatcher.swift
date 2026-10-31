import Foundation

/// Match rank used to keep stronger search results ahead of fuzzy matches.
public enum AppSearchMatchRank: Int, Comparable, Sendable {
    case exactName
    case namePrefix
    case nameSubstring
    case existingMetadata
    case orderedCharacters

    public static func < (lhs: AppSearchMatchRank, rhs: AppSearchMatchRank) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Case- and diacritic-insensitive application search with an ordered-letter fallback.
public struct AppSearchMatcher: Sendable {
    private let query: String
    private let compactQuery: String

    public init(query: String) {
        let normalizedQuery = Self.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        self.query = normalizedQuery
        self.compactQuery = Self.compact(normalizedQuery)
    }

    /// Ranks display/original names, note, bundle identifier and both names' pinyin.
    ///
    /// Ordered-character matching removes spaces and punctuation from the app name,
    /// then checks that every query character appears in order. For example, `ps`
    /// matches `Adobe Photoshop`.
    public func rank(
        name: String,
        bundleIdentifier: String,
        pinyin: PinyinSearchMetadata,
        note: String = "",
        alternateName: String? = nil,
        alternatePinyin: PinyinSearchMetadata = .empty
    ) -> AppSearchMatchRank? {
        guard !query.isEmpty else { return nil }

        let normalizedName = Self.normalize(name)
        let normalizedAlternate = alternateName.map(Self.normalize) ?? ""
        if normalizedName == query || normalizedAlternate == query {
            return .exactName
        }
        if normalizedName.hasPrefix(query) || normalizedAlternate.hasPrefix(query) {
            return .namePrefix
        }
        if normalizedName.contains(query) || normalizedAlternate.contains(query) {
            return .nameSubstring
        }

        if Self.normalize(note).contains(query)
            || Self.normalize(bundleIdentifier).contains(query)
            || pinyin.matches(compactQuery)
            || alternatePinyin.matches(compactQuery) {
            return .existingMetadata
        }

        guard !compactQuery.isEmpty,
              Self.containsInOrder(compactQuery, in: Self.compact(normalizedName))
                || Self.containsInOrder(compactQuery, in: Self.compact(normalizedAlternate)) else {
            return nil
        }
        return .orderedCharacters
    }
}

private extension AppSearchMatcher {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    static func compact(_ value: String) -> String {
        String(value.filter { $0.isLetter || $0.isNumber })
    }

    static func containsInOrder(_ query: String, in value: String) -> Bool {
        let queryCharacters = Array(query)
        guard !queryCharacters.isEmpty else { return false }

        var queryIndex = 0
        for character in value where character == queryCharacters[queryIndex] {
            queryIndex += 1
            if queryIndex == queryCharacters.count {
                return true
            }
        }
        return false
    }
}
