import Foundation
import FoundationModels

/// One suggested to-do, booking or standing reminder from a brain dump, waiting for Ian to check.
struct Proposal: Identifiable, Hashable {
    var id = UUID()
    var include = true
    var item: Item
    /// Set when Ian said it repeats ("pay rent on the 1st of every month"): it becomes a standing reminder.
    var repeats: RoutineSchedule?

    func makeRoutine(now: Date = Date()) -> Routine? {
        guard let repeats else { return nil }
        let first: Date
        if let due = item.due, due > now {
            first = item.hasTime ? due : (Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due) ?? due)
        } else {
            first = Routine.occurrence(of: repeats, after: now, anchor: now, calendar: .current)
        }
        return Routine(title: item.title, symbol: "repeat", categoryID: item.categoryID, schedule: repeats,
                       nextDue: first, notes: item.notes)
    }
}

/// The answer shape both Claude and the on-device model fill in.
@Generable
struct SortedDump: Codable, Sendable {
    @Generable
    struct Entry: Codable, Sendable {
        @Guide(description: "Short to-do in the imperative, e.g. 'Book dentist' or 'Dinner with Sam'")
        var title: String
        @Guide(description: "The id of the best-fitting section")
        var category: String
        @Guide(description: "'task' for a to-do, 'event' for a booking, reservation or appointment at a fixed time")
        var kind: String
        @Guide(description: "Due or start date as YYYY-MM-DD, or empty if no date was mentioned")
        var date: String
        @Guide(description: "Time as HH:MM in 24-hour format, or empty if no time was mentioned")
        var time: String
        @Guide(description: "End date as YYYY-MM-DD for bookings that span days, else empty")
        var endDate: String
        @Guide(description: "End time as HH:MM, else empty")
        var endTime: String
        @Guide(description: "Venue or address, else empty")
        var location: String
        @Guide(description: "Booking or confirmation reference, else empty")
        var reference: String
        @Guide(description: "Useful extra detail in a few words, else empty")
        var notes: String
        @Guide(description: "True only if it was said to be urgent or important")
        var flagged: Bool
        @Guide(description: "'none', 'hours', 'weekly' or 'monthly'")
        var repeatType: String
        @Guide(description: "For 'hours': the gap in hours (3.5 days = 84). Else 0")
        var repeatHours: Double
        @Guide(description: "For 'weekly': weekdays, 1 = Sunday to 7 = Saturday. Else empty")
        var repeatWeekdays: [Int]
        @Guide(description: "For 'monthly': day of the month, 1-31. Else 0")
        var repeatDay: Int

        init(title: String, category: String, kind: String, date: String, time: String, endDate: String,
             endTime: String, location: String, reference: String, notes: String, flagged: Bool,
             repeatType: String, repeatHours: Double, repeatWeekdays: [Int], repeatDay: Int) {
            self.title = title
            self.category = category
            self.kind = kind
            self.date = date
            self.time = time
            self.endDate = endDate
            self.endTime = endTime
            self.location = location
            self.reference = reference
            self.notes = notes
            self.flagged = flagged
            self.repeatType = repeatType
            self.repeatHours = repeatHours
            self.repeatWeekdays = repeatWeekdays
            self.repeatDay = repeatDay
        }
    }

    var items: [Entry]

    init(items: [Entry]) {
        self.items = items
    }
}

enum Sorter {
    struct Outcome {
        var proposals: [Proposal]
        var note: String?
    }

    // MARK: - Entry points

    /// Turns a ramble into separate to-dos, each in a section, with dates where they were said.
    static func sort(_ text: String, categories: [Category], source: Item.Source, now: Date = Date()) async -> Outcome {
        let task = instructions(categories: categories, now: now, shared: false)
        let prompt = "Here is what Ian said:\n\n\(text)"
        return await run(system: task, prompt: prompt, fallbackText: text, categories: categories, source: source, now: now)
    }

    /// Reads something shared from another app (a booking email, web page or screenshot).
    static func sortShared(_ drop: SharedDrop, categories: [Category], now: Date = Date()) async -> Outcome {
        let task = instructions(categories: categories, now: now, shared: true)
        var prompt = "Shared from another app"
        if !drop.comment.isEmpty { prompt += " (Ian added: \"\(drop.comment)\")" }
        if !drop.link.isEmpty { prompt += "\nLink: \(drop.link)" }
        prompt += ":\n\n\(String(drop.text.prefix(12000)))"
        var outcome = await run(system: task, prompt: prompt, fallbackText: drop.comment.isEmpty ? drop.text : drop.comment,
                                categories: categories, source: .shared, now: now)
        for index in outcome.proposals.indices where outcome.proposals[index].item.link.isEmpty {
            outcome.proposals[index].item.link = drop.link
        }
        return outcome
    }

    private static func run(system: String, prompt: String, fallbackText: String, categories: [Category],
                            source: Item.Source, now: Date) async -> Outcome {
        var note: String?
        if KeyStore.hasClaudeKey {
            do {
                let result = try await Claude.structured(SortedDump.self, model: Claude.sonnet, system: system,
                                                         content: [["type": "text", "text": prompt]],
                                                         schema: schema, effort: "low", maxTokens: 6000)
                return Outcome(proposals: proposals(from: result, categories: categories, source: source, now: now))
            } catch {
                note = "Claude couldn't help (\((error as? LocalizedError)?.errorDescription ?? "error")), so this was sorted on your phone."
            }
        }
        if SystemLanguageModel.default.isAvailable {
            do {
                let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                let session = LanguageModelSession(model: model, instructions: system)
                let response = try await session.respond(to: prompt, generating: SortedDump.self,
                                                         options: GenerationOptions(temperature: 0.1))
                let result = proposals(from: response.content, categories: categories, source: source, now: now)
                if !result.isEmpty { return Outcome(proposals: result, note: note) }
            } catch {
                note = note ?? "Your phone's built-in AI couldn't sort this one, so it's been split up simply."
            }
        } else if note == nil {
            note = "Add your Claude key in Settings (or turn on Apple Intelligence) for smarter sorting."
        }
        return Outcome(proposals: basicSplit(fallbackText, categories: categories, source: source, now: now), note: note)
    }

    // MARK: - Instructions

    static func instructions(categories: [Category], now: Date, shared: Bool) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_GB")
        dateFormatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        let sections = categories.map { "- \($0.id): \($0.name)\($0.hint.isEmpty ? "" : " (\($0.hint))")" }.joined(separator: "\n")
        var text = """
        You organise Ian's to-do list. Right now it is \(dateFormatter.string(from: now)) (\(iso.string(from: now))) in \(TimeZone.current.identifier).

        Sections (use the id):
        \(sections)

        """
        if shared {
            text += """
            Ian has shared something from another app: usually a booking or reservation confirmation (restaurant, flight, hotel, theatre, concert, appointment), an invitation, or a page with something to do.
            - For a booking, make one 'event' with the start date and time, the end if given, the venue name and address as location, the confirmation number as reference, and short notes (party size, seat, flight number, check-in time).
            - Use local times as written. Flights: start = departure, end = arrival.
            - If it holds a deadline or a task ("pay by 3 Nov", "reply by Friday"), add it as a 'task' too.
            - Ignore marketing, legal small print and footers.
            """
        } else {
            text += """
            Ian has rambled out loud about everything on his mind. Pull out each separate thing he needs to do or remember.
            - One entry per action. Split "call mum and book the dentist" into two.
            - Title: short and clear, starting with a capital, no full stop, British English. Keep names, places and amounts.
            - Drop filler, thinking out loud and anything that isn't something to do or remember.
            - If he corrects himself, keep only the correction.
            """
        }
        text += """

        - Dates: work out the real date from words like "tomorrow", "Friday" (the next one coming), "next Tuesday", "end of the month", "this weekend" (Saturday). If no day is mentioned, leave date empty. Never make one up.
        - Time: only if one is said ("at 3", "7pm", "tonight" = 19:00, "this morning" = 09:00, "lunch" = 12:30). Otherwise empty.
        - kind 'event' for anything at a fixed time with other people or a venue (dinner booking, appointment, flight, meeting). Everything else is 'task'.
        - repeatType only when he says it repeats ("every month", "each Sunday", "twice a week, 3.5 days apart" = hours 84). Otherwise 'none'.
        - flagged only when he says it's urgent or important.
        - Pick the section that fits best; never invent new section ids.
        """
        return text
    }

    static let schema: [String: Any] = {
        func str() -> [String: Any] { ["type": "string"] }
        let entry: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "category", "kind", "date", "time", "endDate", "endTime", "location", "reference",
                         "notes", "flagged", "repeatType", "repeatHours", "repeatWeekdays", "repeatDay"],
            "properties": [
                "title": str(), "category": str(),
                "kind": ["type": "string", "enum": ["task", "event"]],
                "date": str(), "time": str(), "endDate": str(), "endTime": str(),
                "location": str(), "reference": str(), "notes": str(),
                "flagged": ["type": "boolean"],
                "repeatType": ["type": "string", "enum": ["none", "hours", "weekly", "monthly"]],
                "repeatHours": ["type": "number"],
                "repeatWeekdays": ["type": "array", "items": ["type": "integer"]],
                "repeatDay": ["type": "integer"]
            ]
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["items"],
            "properties": ["items": ["type": "array", "items": entry]]
        ]
    }()

    // MARK: - Turning answers into suggestions

    static func proposals(from result: SortedDump, categories: [Category], source: Item.Source,
                          now: Date = Date()) -> [Proposal] {
        let calendar = Calendar.current
        let validIDs = Set(categories.map(\.id))
        let fallbackID = validIDs.contains("personal") ? "personal" : (categories.first?.id ?? "personal")

        return result.items.compactMap { entry in
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            var item = Item(title: title, categoryID: validIDs.contains(entry.category) ? entry.category : fallbackID)
            item.kind = entry.kind == "event" ? .event : .task
            item.source = source
            item.notes = entry.notes
            item.location = entry.location
            item.reference = entry.reference
            item.flagged = entry.flagged

            let day = parseDay(entry.date)
            let time = parseTime(entry.time)
            if let day {
                if let time {
                    item.due = calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: day)
                    item.hasTime = true
                } else {
                    item.due = day
                }
            } else if let time {
                // A time with no day: today if it's still ahead, otherwise tomorrow.
                var date = calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: now)!
                if date < now { date = calendar.date(byAdding: .day, value: 1, to: date)! }
                item.due = date
                item.hasTime = true
            }
            if item.kind == .event, let start = item.due {
                let endDay = parseDay(entry.endDate) ?? calendar.startOfDay(for: start)
                if let endTime = parseTime(entry.endTime) {
                    item.end = calendar.date(bySettingHour: endTime.0, minute: endTime.1, second: 0, of: endDay)
                } else if parseDay(entry.endDate) != nil {
                    item.end = calendar.date(byAdding: .day, value: 1, to: endDay)
                }
                if let end = item.end, end <= start { item.end = nil }
                if !item.hasTime && item.end == nil {
                    item.end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
                }
            }
            if item.kind == .event && item.due == nil { item.kind = .task }

            var repeats: RoutineSchedule?
            let hour = time?.0 ?? 9
            let minute = time?.1 ?? 0
            switch entry.repeatType {
            case "hours" where entry.repeatHours >= 1:
                repeats = .every(hours: entry.repeatHours)
            case "weekly":
                let days = entry.repeatWeekdays.filter { (1...7).contains($0) }
                if !days.isEmpty { repeats = .weekdays(days: days, hour: hour, minute: minute) }
            case "monthly" where (1...31).contains(entry.repeatDay):
                repeats = .monthly(day: entry.repeatDay, hour: hour, minute: minute)
            default: break
            }
            if repeats != nil { item.kind = .task }
            return Proposal(item: item, repeats: repeats)
        }
    }

    static func parseDay(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func parseTime(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    // MARK: - Without any AI

    /// Splits a ramble into sentences and reads dates with the phone's own date finder.
    static func basicSplit(_ text: String, categories: [Category], source: Item.Source, now: Date = Date()) -> [Proposal] {
        var pieces: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { pieces.append(sentence) }
        }
        let separators = [" and also ", " also ", " and then ", "\n", ";"]
        for separator in separators {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        return pieces.compactMap { piece -> Proposal? in
            var item = QuickParse.item(from: piece, categories: categories, now: now)
            guard let parsed = item, parsed.title.count > 1 else { return nil }
            item?.source = source
            return Proposal(item: item ?? parsed)
        }
    }
}

/// Reads a typed line like "Call Sam tomorrow at 3pm" without any AI: finds the date and guesses the section.
enum QuickParse {
    static func item(from text: String, categories: [Category], now: Date = Date()) -> Item? {
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !title.isEmpty else { return nil }
        var due: Date?
        var hasTime = false

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let date = match.date, let range = Range(match.range, in: title) {
            let phrase = title[range].lowercased()
            hasTime = phrase.range(of: #"\d(:\d\d)?\s*(am|pm)|\d:\d\d|noon|midday|tonight|morning|evening|afternoon|\bat \d"#,
                                   options: .regularExpression) != nil
            due = hasTime ? date : Calendar.current.startOfDay(for: date)
            title.removeSubrange(range)
            title = title.replacingOccurrences(of: #"\s+(on|at|by|for)\s*$"#, with: "", options: .regularExpression)
            title = title.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        title = title.replacingOccurrences(of: #"^(?i)(i need to|i have to|i've got to|i gotta|need to|have to|remember to|don't forget to|must)\s+"#,
                                           with: "", options: .regularExpression)
        guard !title.isEmpty else { return nil }
        title = title.prefix(1).uppercased() + title.dropFirst()

        var item = Item(title: title, categoryID: guessCategory(for: title, categories: categories))
        item.due = due
        item.hasTime = hasTime
        return item
    }

    static let keywords: [String: [String]] = [
        "work": ["work", "office", "client", "meeting", "deck", "memo", "deal", "boss", "colleague", "email", "call with", "pitch", "model", "invus", "board", "report"],
        "social": ["dinner", "drinks", "party", "birthday", "friend", "mum", "dad", "brother", "sister", "text", "message", "catch up", "wedding", "gift", "present", "invite"],
        "home": ["clean", "laundry", "wash", "tidy", "fix", "repair", "flat", "apartment", "kitchen", "bins", "hoover", "vacuum", "dishes", "groceries", "plant"],
        "errands": ["buy", "pick up", "collect", "return", "post", "shop", "drop off", "dry clean", "pharmacy", "order"],
        "health": ["doctor", "dentist", "gp", "prescription", "pill", "mounjaro", "gym", "run", "workout", "appointment", "omnipod", "pod", "insulin", "physio"],
        "money": ["pay", "rent", "bill", "bank", "tax", "insurance", "invoice", "form", "renew", "subscription", "transfer", "card"],
        "personal": ["read", "book", "learn", "write", "journal", "travel", "holiday", "trip"]
    ]

    static func guessCategory(for title: String, categories: [Category]) -> String {
        let lower = " " + title.lowercased() + " "
        var best: (String, Int)?
        for category in categories {
            var words = keywords[category.id] ?? []
            words += category.hint.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            words.append(category.name.lowercased())
            let score = words.filter { !$0.isEmpty && lower.contains(" " + $0) }.count
            if score > 0 && score > (best?.1 ?? 0) { best = (category.id, score) }
        }
        if let best { return best.0 }
        return categories.contains { $0.id == "personal" } ? "personal" : (categories.first?.id ?? "personal")
    }
}
