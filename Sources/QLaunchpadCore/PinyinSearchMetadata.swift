import Foundation

/// Compact pinyin search keys for a display name.
///
/// `CFStringTransform` maps each Han character to a single Unihan default, so
/// 音乐 becomes `yinle` / `yl`. Search also keeps the other common readings
/// (乐 → yue) and the word-level tokenizer transcription (音乐 → yinyue) so
/// both `yy` and `yinyue` match.
public struct PinyinSearchMetadata: Hashable, Sendable {
    /// Per-syllable readings. Latin runs stay one syllable; each Han character
    /// is one syllable with every known reading.
    private let segments: [[String]]
    /// Context-aware compact transcription from `CFStringTokenizer`, when any.
    private let contextualFull: String

    public static let empty = PinyinSearchMetadata(segments: [], contextualFull: "")

    public static func make(for value: String) -> PinyinSearchMetadata {
        let hasCJK = value.unicodeScalars.contains(where: isCJKScalar)
        guard hasCJK else { return .empty }

        let segments = syllables(in: value)
        guard !segments.isEmpty else { return .empty }
        return PinyinSearchMetadata(
            segments: segments,
            contextualFull: contextualTranscription(for: value)
        )
    }

    public func matches(_ compactQuery: String) -> Bool {
        guard !compactQuery.isEmpty else { return false }
        let query = Array(compactQuery)
        return matchesFull(query) || matchesInitials(query)
    }

    private func matchesFull(_ query: [Character]) -> Bool {
        if !contextualFull.isEmpty, contextualFull.contains(String(query)) {
            return true
        }
        for start in segments.indices {
            for reading in segments[start] {
                let chars = Array(reading)
                for offset in chars.indices where consumeFull(
                    query,
                    queryIndex: 0,
                    segmentIndex: start,
                    reading: chars,
                    offset: offset
                ) {
                    return true
                }
            }
        }
        return false
    }

    private func consumeFull(
        _ query: [Character],
        queryIndex: Int,
        segmentIndex: Int,
        reading: [Character],
        offset: Int
    ) -> Bool {
        var queryIndex = queryIndex
        var offset = offset
        while offset < reading.count && queryIndex < query.count {
            if reading[offset] != query[queryIndex] {
                return false
            }
            offset += 1
            queryIndex += 1
        }
        if queryIndex == query.count {
            return true
        }
        let next = segmentIndex + 1
        guard next < segments.count else { return false }
        return segments[next].contains {
            consumeFull(
                query,
                queryIndex: queryIndex,
                segmentIndex: next,
                reading: Array($0),
                offset: 0
            )
        }
    }

    private func matchesInitials(_ query: [Character]) -> Bool {
        let options: [[Character]] = segments.map { readings in
            Array(Set(readings.compactMap(\.first)))
        }
        guard !options.isEmpty else { return false }
        for start in options.indices {
            if matchInitials(query, options: options, queryIndex: 0, segmentIndex: start) {
                return true
            }
        }
        return false
    }

    private func matchInitials(
        _ query: [Character],
        options: [[Character]],
        queryIndex: Int,
        segmentIndex: Int
    ) -> Bool {
        if queryIndex == query.count {
            return true
        }
        if segmentIndex >= options.count {
            return false
        }
        return options[segmentIndex].contains(query[queryIndex])
            && matchInitials(
                query,
                options: options,
                queryIndex: queryIndex + 1,
                segmentIndex: segmentIndex + 1
            )
    }
}

private extension PinyinSearchMetadata {
    static func syllables(in value: String) -> [[String]] {
        var result: [[String]] = []
        var latin = ""

        func flushLatin() {
            let compact = compactLatin(latin, transform: false)
            if !compact.isEmpty {
                result.append([compact])
            }
            latin = ""
        }

        for character in value {
            if character.unicodeScalars.contains(where: isCJKScalar) {
                flushLatin()
                let readings = readings(for: character)
                if !readings.isEmpty {
                    result.append(readings)
                }
            } else if character.isLetter || character.isNumber {
                latin.append(character)
            } else {
                flushLatin()
            }
        }
        flushLatin()
        return result
    }

    static func readings(for character: Character) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            let compact = compactLatin(raw, transform: false)
            guard !compact.isEmpty, seen.insert(compact).inserted else { return }
            ordered.append(compact)
        }

        extraReadings[character]?.forEach(append)
        append(latinTransform(String(character)))

        if ordered.isEmpty {
            let fallback = String(character).lowercased().filter { $0.isLetter || $0.isNumber }
            if !fallback.isEmpty {
                ordered.append(fallback)
            }
        }
        return ordered
    }

    static func contextualTranscription(for value: String) -> String {
        let nsValue = value as NSString
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            nsValue,
            CFRangeMake(0, nsValue.length),
            kCFStringTokenizerUnitWord,
            Locale(identifier: "zh_CN") as CFLocale
        )
        var parts: [String] = []
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != [] {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer,
                kCFStringTokenizerAttributeLatinTranscription
            ) as? String {
                let compact = compactLatin(latin, transform: false)
                if !compact.isEmpty {
                    parts.append(compact)
                }
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return parts.joined()
    }

    static func latinTransform(_ value: String) -> String {
        compactLatin(value, transform: true)
    }

    static func compactLatin(_ value: String, transform: Bool) -> String {
        let latin = NSMutableString(string: value)
        if transform {
            CFStringTransform(latin, nil, kCFStringTransformToLatin, false)
        }
        CFStringTransform(latin, nil, kCFStringTransformStripCombiningMarks, false)
        return (latin as String).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            true
        default:
            false
        }
    }

    /// Extra pronunciations that the per-character Unihan default misses.
    /// The system transform reading is always merged in, so this table only
    /// lists the other common forms.
    static let extraReadings: [Character: [String]] = [
        "乐": ["yue", "yao"],
        "樂": ["yue", "yao"],
        "行": ["hang"],
        "长": ["chang"],
        "長": ["chang"],
        "重": ["zhong", "chong"],
        "还": ["huan"],
        "還": ["huan"],
        "会": ["kuai"],
        "會": ["kuai"],
        "系": ["ji"],
        "传": ["zhuan"],
        "傳": ["zhuan"],
        "调": ["diao"],
        "調": ["diao"],
        "省": ["xing"],
        "藏": ["zang"],
        "弹": ["dan"],
        "彈": ["dan"],
        "降": ["xiang"],
        "觉": ["jiao"],
        "覺": ["jiao"],
        "朝": ["zhao"],
        "率": ["shuai", "lv"],
        "区": ["ou"],
        "區": ["ou"],
        "曾": ["zeng"],
        "单": ["shan", "chan"],
        "單": ["shan", "chan"],
        "便": ["pian"],
        "卡": ["qia"],
        "折": ["she"],
        "给": ["ji"],
        "給": ["ji"],
        "车": ["ju"],
        "車": ["ju"],
        "解": ["xie"],
        "屏": ["bing"],
        "参": ["shen"],
        "參": ["shen"],
        "盛": ["cheng"],
        "乘": ["sheng"],
        "恶": ["wu"],
        "惡": ["wu"],
        "红": ["gong"],
        "紅": ["gong"],
        "秘": ["bi"],
        "奇": ["ji"],
        "强": ["jiang"],
        "強": ["jiang"],
        "识": ["zhi"],
        "識": ["zhi"],
        "宿": ["xiu"],
        "尾": ["yi"],
        "吓": ["he"],
        "嚇": ["he"],
        "巷": ["hang"],
        "校": ["jiao"],
        "叶": ["xie"],
        "葉": ["xie"],
        "种": ["chong"],
        "種": ["chong"],
        "属": ["shu"],
        "屬": ["shu"],
        "绿": ["lv"],
        "綠": ["lv"],
        "女": ["nv"],
        "说": ["shui", "yue"],
        "說": ["shui", "yue"],
    ]
}
