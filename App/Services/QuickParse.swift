import Foundation

/// Reads a typed or spoken line like "Respond to John TN" or "Call the bank next Monday at 5 p.m. #money"
/// without any AI: works out the day and time (including shorthand), picks a list, and adds tags.
enum QuickParse {
    struct When {
        var due: Date
        var hasTime: Bool
    }

    /// What was recognised in a line, for the live preview while Ian talks or types.
    struct Reading {
        var item: Item
        /// The words that set the day or time ("next Monday at 5pm").
        var whenPhrases: [String] = []
        /// The words that filed it in a list ("#work", "work list").
        var listPhrases: [String] = []
        /// The words that became tags ("#wedding").
        var tagPhrases: [String] = []
        /// True if Ian filed it himself (otherwise it goes to Unsorted).
        var filed: Bool { !listPhrases.isEmpty }
    }

    static func item(from text: String, categories: [Category], now: Date = Date(), calendar: Calendar = .current) -> Item? {
        read(text, categories: categories, now: now, calendar: calendar)?.item
    }

    static func read(_ text: String, categories: [Category], now: Date = Date(), calendar: Calendar = .current) -> Reading? {
        var working = " " + expandShorthand(text.trimmingCharacters(in: .whitespacesAndNewlines)) + " "
        var listPhrases: [String] = []
        var tagPhrases: [String] = []

        // #tags and #list names.
        var tags: [String] = []
        var categoryID: String?
        for match in matches(#"(?<!\w)#([\p{L}\p{N}][\p{L}\p{N}_-]*)"#, in: working).reversed() {
            let word = match.groups[0]
            let phrase = String(working[match.range])
            if let list = category(named: word, in: categories) {
                categoryID = categoryID ?? list
                listPhrases.append(phrase)
            } else {
                tags.insert(tidyTag(word), at: 0)
                tagPhrases.append(phrase)
            }
            working.replaceSubrange(match.range, with: " ")
        }

        var whenPhrases: [String] = []
        let when = findWhen(in: &working, now: now, calendar: calendar, phrases: &whenPhrases)
        if categoryID == nil, let mention = listMention(in: &working, categories: categories) {
            categoryID = mention.0
            listPhrases.append(mention.1)
        }

        var title = working
        title = title.replacingOccurrences(of: #"(?i)\s+(on|at|by|for|before|until|till|due)\s*$"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:-–!")))
        title = title.replacingOccurrences(of: #"^(?i)(i need to|i have to|i've got to|i gotta|i must|i should|need to|have to|got to|remember to|don't forget to|dont forget to|must|todo:?|to do:?)\s+"#,
                                           with: "", options: .regularExpression)
        guard !title.isEmpty else { return nil }
        title = title.prefix(1).uppercased() + title.dropFirst()

        for person in people(in: title) where !tags.contains(where: { $0.caseInsensitiveCompare(person) == .orderedSame }) {
            tags.append(person)
        }

        if categoryID == nil, let keyword = keywordMatch(in: title, categories: categories) {
            categoryID = keyword.0
            listPhrases.append(keyword.1)
        }
        let inbox = categories.first(where: \.isInbox)?.id ?? categories.first?.id ?? Category.inboxID
        var item = Item(title: title, categoryID: categoryID ?? inbox)
        item.due = when?.due
        item.hasTime = when?.hasTime ?? false
        item.tagList = tags
        return Reading(item: item, whenPhrases: whenPhrases, listPhrases: listPhrases, tagPhrases: tagPhrases)
    }

    /// Splits a ramble into the separate things in it (sentences, "and also", new lines).
    static func pieces(of text: String) -> [String] {
        var pieces: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { pieces.append(sentence) }
        }
        let separators = [" and also ", ", oh and ", ", and ", " also ", " and then ", "\n", ";"]
        for separator in separators {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        // Words like "Okay so" and "oh" at the start aren't part of the to-do.
        return pieces.map { $0.replacingOccurrences(of: #"^(?i)\s*(?:okay|ok|so|um|uh|oh|and|also)\b[\s,]*(?:(?:so|um|oh|and)\b[\s,]*)*"#,
                                                    with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Shorthand

    /// Turns texting shorthand into words the parser (and people) understand.
    static func expandShorthand(_ text: String) -> String {
        let swaps: [(String, String)] = [
            (#"(?i)(?<![\w'])(tn|tnite|tonite|2nite|2night|tonigh)(?![\w'])"#, "tonight"),
            (#"(?i)(?<![\w'])(tmrw|tmrow|tmr|tmw|tmoz|tomo|2moro|2morrow|2mrw|tomorow|tommorow|tommorrow)(?![\w'])"#, "tomorrow"),
            (#"(?i)(?<![\w'])(tdy|2day)(?![\w'])"#, "today"),
            (#"(?i)(?<![\w'])(eod|cob|close of play)(?![\w'])"#, "end of day"),
            (#"(?i)(?<![\w'])eow(?![\w'])"#, "end of the week"),
            (#"(?i)(?<![\w'])eom(?![\w'])"#, "end of the month"),
            (#"(?i)(?<![\w'])(nxt|nex)(?![\w'])"#, "next"),
            (#"(?i)(?<![\w'])(wknd|wkend)(?![\w'])"#, "weekend"),
            (#"(?i)(?<![\w'])(wk)(?![\w'])"#, "week"),
            (#"(?i)(\d)\s*([ap])\.?\s?m\.?(?![\w])"#, "$1$2m"),
            (#"(?i)(?<![\w'])asap(?![\w'])"#, "today"),
            // Spoken "hashtag work" or "hash work".
            (#"(?i)(?<![\w'])(?:hashtag|hash tag)\s+([\p{L}\p{N}][\p{L}\p{N}_-]*)"#, "#$1")
        ]
        var result = text
        for (pattern, replacement) in swaps {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    // MARK: - Dates and times

    private static let weekdayWords: [(String, Int, Bool)] = [
        // word, weekday (1 = Sunday), needs "on/by/next/this" in front (short forms that are also ordinary words)
        ("sunday", 1, false), ("sun", 1, true),
        ("monday", 2, false), ("mon", 2, true),
        ("tuesday", 3, false), ("tues", 3, false), ("tue", 3, false),
        ("wednesday", 4, false), ("weds", 4, false), ("wed", 4, true),
        ("thursday", 5, false), ("thurs", 5, false), ("thur", 5, false), ("thu", 5, false),
        ("friday", 6, false), ("fri", 6, false),
        ("saturday", 7, false), ("sat", 7, true)
    ]

    /// Finds the day and time in a line and removes those words from it.
    static func findWhen(in text: inout String, now: Date, calendar: Calendar) -> When? {
        var phrases: [String] = []
        return findWhen(in: &text, now: now, calendar: calendar, phrases: &phrases)
    }

    static func findWhen(in text: inout String, now: Date, calendar: Calendar, phrases: inout [String]) -> When? {
        let today = calendar.startOfDay(for: now)
        var day: Date?
        var time: (Int, Int)?
        /// A time implied by words like "tonight" or "this morning", used only if no exact time is given.
        var softTime: (Int, Int)?
        var afternoonHint = false

        func take(_ pattern: String, _ handle: ([String]) -> Bool) {
            if let match = matches(pattern, in: text).first, handle(match.groups) {
                phrases.append(String(text[match.range]).trimmingCharacters(in: .whitespaces))
                text.replaceSubrange(match.range, with: " ")
            }
        }

        // Exact times: "5pm", "5:30 pm", "at 5", "17:30", "noon", "end of day".
        take(#"(?i)(?<![\w:])(?:at\s+|@\s*|by\s+|around\s+|about\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)(?![\w])"#) { g in
            guard let h = Int(g[0]), (1...12).contains(h) else { return false }
            let m = Int(g[1]) ?? 0
            guard m < 60 else { return false }
            time = ((h % 12) + (g[2].lowercased() == "pm" ? 12 : 0), m)
            return true
        }
        if time == nil {
            take(#"(?i)(?<![\w:])(?:at\s+|@\s*|by\s+|around\s+)?([01]?\d|2[0-3])[:.]([0-5]\d)(?![\w:])"#) { g in
                guard let h = Int(g[0]), let m = Int(g[1]) else { return false }
                time = (h, m)
                return true
            }
        }
        if time == nil {
            take(#"(?i)(?:\bat|@)\s*(\d{1,2})(?![\w:.])"#) { g in
                guard let h = Int(g[0]), (1...23).contains(h) else { return false }
                time = (h, 0)
                return true
            }
            // A bare "at 5" is read as 5pm (between 1 and 7), else as the morning; fixed up below for "tonight".
            if case let (h, m)? = time, h <= 12 { time = (h <= 7 ? h + 12 : h, m) }
        }
        if time == nil {
            take(#"(?i)\b(?:at\s+|by\s+|around\s+)?(noon|midday|lunchtime|lunch|midnight|end of (?:the )?day|end of business|breakfast|dinnertime)\b"#) { g in
                switch g[0].lowercased() {
                case "noon", "midday": time = (12, 0)
                case "lunch", "lunchtime": time = (12, 30)
                case "midnight": time = (23, 59)
                case "breakfast": time = (8, 0)
                case "dinnertime": time = (19, 0)
                default: time = (17, 0)
                }
                return true
            }
        }

        // Parts of the day.
        take(#"(?i)\b(tonight|this (?:morning|afternoon|evening)|in the (?:morning|afternoon|evening)|(today|tomorrow|tomorrow's) (morning|afternoon|evening|night))\b"#) { g in
            let phrase = g[0].lowercased()
            func part(_ word: String) -> (Int, Int) {
                switch word {
                case "morning": return (9, 0)
                case "afternoon": return (14, 0)
                case "evening": return (18, 0)
                default: return (19, 0)
                }
            }
            if phrase == "tonight" {
                day = day ?? today
                softTime = (19, 0)
                afternoonHint = true
            } else if phrase.hasPrefix("this ") {
                day = day ?? today
                softTime = part(String(phrase.dropFirst(5)))
                afternoonHint = !phrase.hasSuffix("morning")
            } else if phrase.hasPrefix("in the ") {
                let word = String(phrase.dropFirst(7))
                softTime = part(word)
                afternoonHint = word != "morning"
            } else {
                day = g[1].lowercased().hasPrefix("tomorrow") ? calendar.date(byAdding: .day, value: 1, to: today) : today
                softTime = part(g[2].lowercased())
                afternoonHint = g[2].lowercased() != "morning"
            }
            return true
        }

        // Days.
        take(#"(?i)\b(?:on\s+|by\s+|for\s+|before\s+|until\s+|till\s+)?(the day after tomorrow|today|tomorrow)\b"#) { g in
            let word = g[0].lowercased()
            let offset = word == "today" ? 0 : (word == "tomorrow" ? 1 : 2)
            day = calendar.date(byAdding: .day, value: offset, to: today)
            return true
        }
        if day == nil {
            let names = weekdayWords.map(\.0).joined(separator: "|")
            take(#"(?i)\b(on|by|for|before|until|till|next|this|coming|this coming)?\s*(\#(names))\b(?:\s+(next week|week))?"#) { g in
                let prefix = g[0].lowercased()
                let word = g[1].lowercased()
                guard let entry = weekdayWords.first(where: { $0.0 == word }) else { return false }
                if entry.2 && prefix.isEmpty { return false }
                day = weekday(entry.1, prefix: prefix, nextWeek: !g[2].isEmpty, today: today, calendar: calendar)
                return day != nil
            }
        }
        if day == nil {
            take(#"(?i)\b(?:in\s+)(a|an|one|two|three|four|five|six|seven|eight|nine|ten|a couple of|a few|\d+)\s+(minutes?|mins?|hours?|hrs?|days?|weeks?|months?)\b"#) { g in
                let numbers = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                               "eight": 8, "nine": 9, "ten": 10, "a couple of": 2, "a few": 3]
                let n = Int(g[0]) ?? numbers[g[0].lowercased()] ?? 1
                let unit = g[1].lowercased()
                if unit.hasPrefix("min") || unit.hasPrefix("h") {
                    let target = now.addingTimeInterval(Double(n) * (unit.hasPrefix("min") ? 60 : 3600))
                    day = calendar.startOfDay(for: target)
                    let parts = calendar.dateComponents([.hour, .minute], from: target)
                    time = time ?? (parts.hour ?? 9, parts.minute ?? 0)
                } else if unit.hasPrefix("day") {
                    day = calendar.date(byAdding: .day, value: n, to: today)
                } else if unit.hasPrefix("week") {
                    day = calendar.date(byAdding: .day, value: 7 * n, to: today)
                } else {
                    day = calendar.date(byAdding: .month, value: n, to: today)
                }
                return true
            }
        }
        if day == nil {
            take(#"(?i)\b(?:by\s+|on\s+|for\s+|over\s+|at\s+)?(next week|next month|this weekend|the weekend|weekend|end of (?:the |this )?week|end of (?:the |this )?month|later this week|this week|next weekend)\b"#) { g in
                let phrase = g[0].lowercased()
                let weekdayToday = calendar.component(.weekday, from: today)
                func upcoming(_ weekday: Int, includeToday: Bool) -> Date? {
                    var gap = (weekday - weekdayToday + 7) % 7
                    if gap == 0 && !includeToday { gap = 7 }
                    return calendar.date(byAdding: .day, value: gap, to: today)
                }
                switch phrase {
                case "next week":
                    day = upcoming(2, includeToday: false)
                case "next month":
                    let month = calendar.date(byAdding: .month, value: 1, to: today)!
                    day = calendar.dateInterval(of: .month, for: month)?.start
                case "next weekend":
                    day = upcoming(7, includeToday: true).flatMap { calendar.date(byAdding: .day, value: 7, to: $0) }
                case let p where p.contains("weekend"):
                    day = upcoming(7, includeToday: true)
                case let p where p.contains("month"):
                    day = calendar.dateInterval(of: .month, for: today).flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) }
                default:
                    day = upcoming(6, includeToday: true)
                }
                return day != nil
            }
        }

        // "Friday morning", "next Tuesday evening".
        if day != nil && softTime == nil {
            take(#"(?i)\b(morning|afternoon|evening|night)\b"#) { g in
                let word = g[0].lowercased()
                softTime = word == "morning" ? (9, 0) : (word == "afternoon" ? (14, 0) : (word == "evening" ? (18, 0) : (19, 0)))
                afternoonHint = word != "morning"
                return true
            }
        }

        // Anything else ("5 November", "the 12th", "11/5") goes to the phone's own date finder.
        if day == nil, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let date = match.date, let range = Range(match.range, in: text) {
            let phrase = text[range].lowercased()
            let timed = phrase.range(of: #"\d:\d\d|\d\s*(am|pm)"#, options: .regularExpression) != nil
            day = calendar.startOfDay(for: date)
            if timed && time == nil {
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                time = (parts.hour ?? 9, parts.minute ?? 0)
            }
            phrases.append(String(text[range]))
            text.replaceSubrange(range, with: " ")
            // Drop a dangling "on the" left behind.
            text = text.replacingOccurrences(of: #"(?i)\s+(on|by)\s+the\s*$"#, with: " ", options: .regularExpression)
        }

        // "at 8 tonight" means 8pm.
        if case let (h, m)? = time, afternoonHint, h < 12 { time = (h + 12, m) }
        if time == nil { time = softTime }

        guard day != nil || time != nil else { return nil }
        if case let (h, m)? = time {
            var base = day ?? today
            var date = calendar.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
            // A time with no day: today if it's still to come, otherwise tomorrow.
            if day == nil && date <= now {
                base = calendar.date(byAdding: .day, value: 1, to: base)!
                date = calendar.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
            }
            return When(due: date, hasTime: true)
        }
        return When(due: day!, hasTime: false)
    }

    /// "Friday" and "this Friday" mean the next Friday to come; "next Friday" means the one in next week.
    static func weekday(_ weekday: Int, prefix: String, nextWeek: Bool, today: Date, calendar: Calendar) -> Date? {
        let weekdayToday = calendar.component(.weekday, from: today)
        var gap = (weekday - weekdayToday + 7) % 7
        if gap == 0 { gap = 7 }
        if prefix == "next" || nextWeek {
            // Monday-start weeks: if that day is still to come this week, "next" means a week later.
            let mondayIndex = { (w: Int) in (w + 5) % 7 }  // Monday 0 … Sunday 6
            if mondayIndex(weekday) > mondayIndex(weekdayToday) { gap += 7 }
        }
        return calendar.date(byAdding: .day, value: gap, to: today)
    }

    // MARK: - Lists, tags and people

    private static func normalised(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func category(named word: String, in categories: [Category]) -> String? {
        let key = normalised(word)
        guard !key.isEmpty else { return nil }
        return categories.first { normalised($0.name) == key || $0.id == key
            || normalised($0.name).hasPrefix(key) && key.count >= 4 }?.id
    }

    static func tidyTag(_ word: String) -> String {
        let spaced = word.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private static let notNames: Set<String> = [
        "I", "The", "A", "An", "My", "Me", "It", "This", "That", "Them", "Him", "Her", "Us", "You", "Everyone",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
        "Today", "Tomorrow", "Tonight", "Work", "Home", "Office", "Bank", "Doctor", "Dentist", "Amazon", "Apple", "Google", "Uber"
    ]

    /// First names after words like "to", "with", "call": "Respond to John" → John.
    static func people(in title: String) -> [String] {
        let pattern = #"(?i:\b(?:to|with|for|from|call|ring|text|email|e-mail|message|tell|ask|meet|see|thank|invite|remind|pay|reply to|respond to|get back to|follow up with|catch up with))\s+([A-Z][a-z]{1,15})(?:\s+([A-Z][a-z]{1,15}))?\b"#
        var names: [String] = []
        for match in matches(pattern, in: title) {
            let first = match.groups[0]
            guard !notNames.contains(first) else { continue }
            var name = first
            if !match.groups[1].isEmpty, !notNames.contains(match.groups[1]) { name += " \(match.groups[1])" }
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// A list Ian named himself: "work list", "on my home list", "for work", "under money", or the
    /// list's name at the very end ("call the bank, money"). Those words are taken out of the title.
    static func listMention(in text: inout String, categories: [Category]) -> (String, String)? {
        for category in categories {
            var names = [category.name.lowercased()]
            // "Money & admin" can also be called "money" or "admin".
            names += category.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init).filter { $0.count >= 4 && !names.contains($0) }
            for name in names {
                let n = NSRegularExpression.escapedPattern(for: name)
                let patterns = [
                    #"(?i)\s*,?\s*\b(?:(?:add|put|file|save)\s+(?:it\s+)?)?(?:(?:on|to|in|into|onto|under)\s+)?(?:the\s+|my\s+)?"# + n + #"\s+list\b"#,
                    #"(?i)\s*,?\s*\b(?:(?:add|put|file|save)\s+(?:it\s+)?)?(?:for|under|in|into)\s+(?:the\s+|my\s+)?"# + n + #"(?=\s*(?:[,;:.!]|$))"#,
                    #"(?i)[,;:–—-]\s*"# + n + #"[\s.!]*$"#
                ]
                for pattern in patterns {
                    if let match = matches(pattern, in: text).first {
                        let phrase = String(text[match.range]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.!–—-"))
                        text.replaceSubrange(match.range, with: " ")
                        return (category.id, phrase)
                    }
                }
            }
        }
        return nil
    }

    /// One of the extra keywords Ian set on a list (Lists → edit a list), said anywhere as a whole word.
    static func keywordMatch(in text: String, categories: [Category]) -> (String, String)? {
        let lower = text.lowercased()
        for category in categories {
            for keyword in category.keywords {
                let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: keyword) + #"(?![\p{L}\p{N}])"#
                if lower.range(of: pattern, options: .regularExpression) != nil { return (category.id, keyword) }
            }
        }
        return nil
    }

    /// The list a line belongs in: one Ian named or a keyword he set, otherwise Unsorted.
    static func guessCategory(for title: String, categories: [Category]) -> String {
        var text = " " + title + " "
        if let mention = listMention(in: &text, categories: categories) { return mention.0 }
        if let keyword = keywordMatch(in: title, categories: categories) { return keyword.0 }
        return categories.first(where: \.isInbox)?.id ?? categories.first?.id ?? Category.inboxID
    }

    /// True if Ian's own words point at this list (its name, #name or one of its keywords).
    static func mentions(_ category: Category, in text: String) -> Bool {
        if category.isInbox { return true }
        var copy = " " + expandShorthand(text) + " "
        if listMention(in: &copy, categories: [category]) != nil { return true }
        if keywordMatch(in: text, categories: [category]) != nil { return true }
        let hashes = matches(#"#([\p{L}\p{N}][\p{L}\p{N}_-]*)"#, in: expandShorthand(text)).map { $0.groups[0] }
        return hashes.contains { QuickParse.category(named: $0, in: [category]) != nil }
    }

    // MARK: - Regex helper

    struct Match {
        var range: Range<String.Index>
        /// Capture groups (empty string when a group didn't take part).
        var groups: [String]
    }

    static func matches(_ pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let groups = (1..<max(result.numberOfRanges, 1)).map { index -> String in
                guard let r = Range(result.range(at: index), in: text) else { return "" }
                return String(text[r])
            }
            return Match(range: range, groups: groups)
        }
    }
}
