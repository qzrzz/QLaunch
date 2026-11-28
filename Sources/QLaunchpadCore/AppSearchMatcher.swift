import Foundation

/// Match rank used to keep stronger search results ahead of fuzzy matches.
public enum AppSearchMatchRank: Int, CaseIterable, Comparable, Sendable {
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
    private let compactQueryIsASCII: Bool

    public var isEmpty: Bool { query.isEmpty }

    public init(query: String) {
        let normalizedQuery = Self.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let compactQuery = Self.compact(normalizedQuery)
        self.query = normalizedQuery
        self.compactQuery = compactQuery
        self.compactQueryIsASCII = compactQuery.utf8.allSatisfy { $0 < 0x80 }
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
        guard !isEmpty else { return nil }

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
              containsInOrder(normalizedName) || containsInOrder(normalizedAlternate) else {
            return nil
        }
        return .orderedCharacters
    }
}

private extension AppSearchMatcher {
    static func normalize(_ value: String) -> String {
        // Capital I needs the locale-aware path for Turkic case folding.
        if value.utf8.allSatisfy({ $0 < 0x80 && $0 != UInt8(ascii: "I") }) {
            return value.lowercased()
        }
        return value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    static func compact(_ value: String) -> String {
        String(value.filter { $0.isLetter || $0.isNumber })
    }

    func containsInOrder(_ value: String) -> Bool {
        let isASCII = value.utf8.allSatisfy { $0 < 0x80 }
        if compactQueryIsASCII, isASCII {
            var queryBytes = compactQuery.utf8.makeIterator()
            guard var wanted = queryBytes.next() else { return false }
            for byte in value.utf8 where byte == wanted {
                guard let next = queryBytes.next() else { return true }
                wanted = next
            }
            return false
        }

        // ASCII separators never match a compact query. Keep the Unicode
        // compaction because removing a separator can join grapheme clusters.
        let candidate = isASCII ? value : Self.compact(value)
        var queryIndex = compactQuery.startIndex
        var nextCharacter = compactQuery[queryIndex]
        for character in candidate where character == nextCharacter {
            compactQuery.formIndex(after: &queryIndex)
            if queryIndex == compactQuery.endIndex {
                return true
            }
            nextCharacter = compactQuery[queryIndex]
        }
        return false
    }
}
