import Foundation

/// Zero-latency structuring of dictated text, applied to live partials and the final paste.
/// - Spoken layout commands: "new line" / "neue Zeile", "new paragraph" / "neuer Absatz".
/// - Enumerations: "erstens A, zweitens B" or "first A, second B" → a numbered list, as soon as the
///   second marker is spoken. A lone "first" never makes a list.
enum TextFormatter {
    static func format(_ text: String) -> String {
        var s = applyCommands(text)
        s = formatLists(s)
        return capitalizeLineStarts(s)
    }

    // MARK: - Layout commands

    private static let commands: [(pattern: String, replacement: String)] = [
        ("new paragraph|next paragraph|neuer absatz|nächster absatz|neuer paragra(?:ph|f)", "\n\n"),
        ("new ?line|next line|neue zeile|nächste zeile|zeilenumbruch", "\n"),
    ]

    private static func applyCommands(_ s: String) -> String {
        var out = s
        for (words, replacement) in commands {
            // swallow a comma before and any punctuation after the command; a period before it stays
            let re = regex("\\s*[,;]?\\s*(?<![\\p{L}])(?:\(words))(?![\\p{L}])[.,;:!]?\\s*", caseInsensitive: true)
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
        }
        return out
    }

    // MARK: - Numbered lists

    private static let ordinalEN = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let cardinalEN = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let adverbDE = ["erstens", "zweitens", "drittens", "viertens", "fünftens", "sechstens", "siebtens", "achtens", "neuntens", "zehntens"]
    private static let stemDE = ["erst", "zweit", "dritt", "viert", "fünft", "sechst", "siebt", "acht", "neunt", "zehnt"]
    private static let cardinalDE = ["eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn"]

    /// One regex per list position (index 0 = item 1).
    private static let markers: [NSRegularExpression] = (0..<10).map { i in
        var alts = [
            "\(ordinalEN[i])(?:ly)?",
            "(?:number|point|step|item)\\s+(?:\(cardinalEN[i])|\(i + 1))",
            adverbDE[i],
            "(?:punkt|nummer|schritt)\\s+(?:\(cardinalDE[i])|\(i + 1))",
            "\(stemDE[i])(?:er|es|e)?\\s+punkt",
            "als\\s+\(stemDE[i])(?:es|e)",
        ]
        if i == 0 { alts.insert("first of all", at: 0) }
        return regex("(?<![\\p{L}\\d])(?:\(alts.joined(separator: "|")))(?![\\p{L}\\d])\\s*[,:.]?\\s*", caseInsensitive: true)
    }

    /// A marker only counts at the start of a clause, so "the first time" or "a second" stay prose.
    private static let clauseStart = regex("(?:^|[.,;:!?\\n]|(?<![\\p{L}])(?:und|and|sowie|dann|then))\\s*$", caseInsensitive: true)
    private static let trailingJoiner = regex("(?:[,;]\\s*)?(?:(?<![\\p{L}])(?:und|and|sowie|dann|then))?[\\s,;]*$", caseInsensitive: true)

    private struct Marker { let number: Int; let range: NSRange }

    private static func findMarkers(in s: NSString) -> [Marker] {
        var found: [Marker] = []
        for (i, re) in markers.enumerated() {
            for m in re.matches(in: s as String, range: NSRange(location: 0, length: s.length)) {
                let before = s.substring(to: m.range.location)
                guard clauseStart.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil else { continue }
                found.append(Marker(number: i + 1, range: m.range))
            }
        }
        // "first of all" and "first" can both match at the same spot: keep the longest per location.
        found.sort { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
        var out: [Marker] = []
        for m in found where out.last.map({ NSMaxRange($0.range) <= m.range.location }) ?? true {
            out.append(m)
        }
        return out
    }

    private static func formatLists(_ text: String) -> String {
        let s = text as NSString
        let found = findMarkers(in: s)
        // first run 1, 2, 3, … with at least two items
        guard let startIdx = found.indices.first(where: { found[$0].number == 1 }) else { return text }
        var run = [found[startIdx]]
        for m in found[(startIdx + 1)...] where m.number == run.count + 1 { run.append(m) }
        guard run.count >= 2 else { return text }

        var intro = s.substring(to: run[0].range.location)
        intro = strip(intro, trailingJoiner)
        if !intro.isEmpty {
            if intro.hasSuffix(",") || intro.hasSuffix(";") { intro.removeLast() }
            if let last = intro.last, !":.!?\n".contains(last) { intro += ":" }
        }

        var items: [String] = []
        var rest = ""
        for (k, m) in run.enumerated() {
            let start = NSMaxRange(m.range)
            let end = k + 1 < run.count ? run[k + 1].range.location : s.length
            var item = s.substring(with: NSRange(location: start, length: end - start))
            if k + 1 < run.count {
                item = strip(item, trailingJoiner)
            } else if let stop = item.range(of: "[.!?](?=\\s+\\S)", options: .regularExpression) {
                // the last item ends at its first sentence end; what follows is a new paragraph
                rest = String(item[stop.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                item = String(item[..<stop.upperBound])
            }
            items.append(item.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-\n")))
        }

        var out = intro.isEmpty ? "" : intro + "\n"
        out += items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if !rest.isEmpty { out += "\n\n" + formatLists(rest) }
        return out
    }

    // MARK: - Helpers

    private static func capitalizeLineStarts(_ s: String) -> String {
        var out = ""
        var capNext = true
        for ch in s {
            if capNext, ch.isLetter {
                out += ch.uppercased()
                capNext = false
            } else {
                out.append(ch)
                if ch == "\n" { capNext = true } else if !ch.isWhitespace && !ch.isNumber && ch != "." { capNext = false }
            }
        }
        return out
    }

    private static func strip(_ s: String, _ re: NSRegularExpression) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func regex(_ p: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Part of `OpenFlow --selftest`.
    static func selfTest() -> Bool {
        let cases: [(String, String)] = [
            ("Wir haben drei Themen, erstens das Budget, zweitens die Roadmap und drittens das Hiring.",
             "Wir haben drei Themen:\n1. Das Budget\n2. Die Roadmap\n3. Das Hiring."),
            ("First, update the docs. Second, ship the release. Third, tell the team. Thanks everyone.",
             "1. Update the docs.\n2. Ship the release.\n3. Tell the team.\n\nThanks everyone."),
            ("Punkt eins Kaffee, Punkt zwei Milch", "1. Kaffee\n2. Milch"),
            ("The first time I tried it, it worked.", "The first time I tried it, it worked."),
            ("First, let me check that.", "First, let me check that."),
            ("Give me a second, first I need coffee.", "Give me a second, first I need coffee."),
            ("Hallo Team. Neue Zeile. Wie geht's?", "Hallo Team.\nWie geht's?"),
            ("Thanks, new paragraph, best regards", "Thanks\n\nBest regards"),
            ("Erstens, wir starten morgen", "Erstens, wir starten morgen"),  // live partial: no list yet
            ("Erstens, wir starten morgen, zweitens", "1. Wir starten morgen\n2. "),
        ]
        var ok = true
        for (input, expected) in cases {
            let got = format(input)
            let pass = got == expected
            ok = ok && pass
            func show(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "⏎") }
            print("\(pass ? "PASS" : "FAIL")  \(show(input))  ->  \(show(got))\(pass ? "" : "   (expected: \(show(expected)))")")
        }
        return ok
    }
}
