import Foundation

/// Strips spoken fillers and tidies spacing/capitalization.
/// "um" is a real German word ("um zehn Uhr"), so it is only removed when the language is English.
enum FillerFilter {
    private static let common = ["äh+m*", "öh+m*", "ehm+", "hm+", "mhm"]
    private static let english = ["u+m+", "u+h+m*", "erm+"]

    static func clean(_ text: String, lang: String?) -> String {
        var words = common
        if lang?.hasPrefix("en") == true { words += english }
        // filler + optional trailing comma/ellipsis, bounded by non-letters
        let pattern = "(?<![\\p{L}])(?:\(words.joined(separator: "|")))(?![\\p{L}])\\s*(?:,|\\.\\.\\.|…)?"
        var s = replace(text, pattern, "", caseInsensitive: true)
        s = replace(s, "\\s+([,.;:!?])", "$1")      // "Hallo ," -> "Hallo,"
        s = replace(s, ",\\s*([,.;:!?])", "$1")     // ", ." -> "."
        s = replace(s, "^[\\s,;:.]+", "")            // leading punctuation left by a removed filler
        s = replace(s, "\\s{2,}", " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return capitalizeSentences(s)
    }

    private static func capitalizeSentences(_ s: String) -> String {
        var out = ""
        var capNext = true
        for ch in s {
            if capNext, ch.isLetter {
                out += ch.uppercased()
                capNext = false
            } else {
                out.append(ch)
                if ".!?".contains(ch) { capNext = true } else if !ch.isWhitespace { capNext = false }
            }
        }
        return out
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String, caseInsensitive: Bool = false) -> String {
        let re = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// `OpenFlow --selftest`
    static func selfTest() -> Bool {
        let cases: [(String, String?, String)] = [
            ("Um, I think we should, uh, ship it.", "en-US", "I think we should, ship it."),
            ("So, uhm, yeah.", "en-US", "So, yeah."),
            ("Können wir das Meeting morgen um zehn Uhr machen?", "de-DE", "Können wir das Meeting morgen um zehn Uhr machen?"),
            ("Äh, ich schicke euch, ähm, die Präsentation.", "de-DE", "Ich schicke euch, die Präsentation."),
            ("Hmm. Okay, let's go.", "en-US", "Okay, let's go."),
            ("Umbrella and humming stay.", "en-US", "Umbrella and humming stay."),
            ("Das ist, öhm... gut.", nil, "Das ist, gut."),
        ]
        var ok = true
        for (input, lang, expected) in cases {
            let got = clean(input, lang: lang)
            let pass = got == expected
            ok = ok && pass
            print("\(pass ? "PASS" : "FAIL")  \(input)  ->  \(got)\(pass ? "" : "   (expected: \(expected))")")
        }
        return ok
    }
}
