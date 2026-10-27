import Foundation

/// Checks run on the build machine (started with -AgendaSelfTest): schedules, reading dates,
/// turning sorter answers into to-dos, moving things around, nudges and the widget's data.
@MainActor
enum SelfTest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-AgendaSelfTest") }

    /// Returns true if the self-check ran (the app then does nothing else).
    static func runIfRequested() async -> Bool {
        guard isRequested else { return false }
        var results: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            results.append(["check": name, "ok": ok, "detail": detail])
        }
        let calendar = Calendar.current
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }

        // 1. Schedules.
        let sunday = date(2026, 10, 25, 8)
        let twiceWeekly = Routine(title: "Mounjaro", schedule: .every(hours: 84), nextDue: sunday)
        let next = twiceWeekly.nextOccurrence(after: sunday.addingTimeInterval(60))
        check("3½ days after Sun 8am is Wed 8pm", next == date(2026, 10, 28, 20), "\(next)")
        let weekLate = twiceWeekly.nextOccurrence(after: date(2026, 11, 2, 9))
        check("keeps the rhythm when late", weekLate == date(2026, 11, 4, 20), "\(weekLate)")
        let thirtyFirst = Routine.occurrence(of: .monthly(day: 31, hour: 9, minute: 0), after: date(2027, 2, 2),
                                             anchor: date(2027, 2, 2), calendar: calendar)
        check("31st becomes the last day of February", thirtyFirst == date(2027, 2, 28, 9), "\(thirtyFirst)")
        let rent = Routine.occurrence(of: .monthly(day: 1, hour: 9, minute: 0), after: date(2026, 10, 23, 12),
                                      anchor: date(2026, 10, 23, 12), calendar: calendar)
        check("rent next due 1 November", rent == date(2026, 11, 1, 9), "\(rent)")
        let weekly = Routine.occurrence(of: .weekdays(days: [2, 5], hour: 9, minute: 0), after: date(2026, 10, 23, 12),
                                        anchor: date(2026, 10, 23, 12), calendar: calendar)
        check("weekly Mon/Thu after Friday is Monday", weekly == date(2026, 10, 26, 9), "\(weekly)")
        let occurrences = twiceWeekly.occurrences(from: date(2026, 10, 25), to: date(2026, 11, 8))
        check("calendar shows 4 doses in two weeks", occurrences.count == 4, "\(occurrences.count)")
        check("summary reads well", RoutineSchedule.every(hours: 84).summary == "Every 3½ days"
              && RoutineSchedule.monthly(day: 1, hour: 9, minute: 0).summary.hasPrefix("Monthly on the 1st"))

        // 2. Typed to-dos.
        let now = date(2026, 10, 23, 12)
        let cats = Category.defaults
        let call = QuickParse.item(from: "Call Sam tomorrow at 3pm", categories: cats, now: now)
        check("quick add title", call?.title == "Call Sam", call?.title ?? "nil")
        check("quick add time", call?.hasTime == true && call?.due.map { calendar.component(.hour, from: $0) } == 15,
              "\(String(describing: call?.due))")
        let rentTodo = QuickParse.item(from: "I need to pay the rent", categories: cats, now: now)
        check("quick add drops 'I need to' and picks Money", rentTodo?.title == "Pay the rent" && rentTodo?.categoryID == "money",
              "\(rentTodo?.title ?? "") \(rentTodo?.categoryID ?? "")")
        check("quick add with no date", rentTodo?.due == nil)
        check("dinner goes to Social", QuickParse.guessCategory(for: "Dinner with Hannah", categories: cats) == "social")
        let split = Sorter.basicSplit("Buy milk. Call the bank and also clean the kitchen", categories: cats, source: .typed, now: now)
        check("simple split without AI", split.count == 3, split.map(\.item.title).joined(separator: " | "))

        // 2b. Plain words and shorthand for days and times (now is Friday 23 October, midday).
        func parsed(_ text: String) -> Item? { QuickParse.item(from: text, categories: cats, now: now) }
        func expect(_ text: String, title: String, due: Date?, timed: Bool, category: String? = nil, tags: [String]? = nil) {
            let item = parsed(text)
            var ok = item?.title == title && item?.due == due && (due == nil || item?.hasTime == timed)
            if let category { ok = ok && item?.categoryID == category }
            if let tags { ok = ok && item?.tagList == tags }
            check("reads \"\(text)\"", ok,
                  "\(item?.title ?? "nil") | \(item?.due.map { "\($0)" } ?? "no date") | timed \(item?.hasTime ?? false) | \(item?.categoryID ?? "") | \(item?.tagList ?? [])")
        }
        expect("Respond to John TN", title: "Respond to John", due: date(2026, 10, 23, 19), timed: true, category: "work", tags: ["John"])
        expect("respond next Monday at 5 p.m.", title: "Respond", due: date(2026, 10, 26, 17), timed: true)
        expect("Call the bank tmrw 9am #money", title: "Call the bank", due: date(2026, 10, 24, 9), timed: true, category: "money")
        expect("Dinner with Hannah Fri 8pm", title: "Dinner with Hannah", due: date(2026, 10, 30, 20), timed: true, category: "social", tags: ["Hannah"])
        expect("Send deck EOD", title: "Send deck", due: date(2026, 10, 23, 17), timed: true)
        expect("Pay rent in 3 days", title: "Pay rent", due: date(2026, 10, 26), timed: false, category: "money")
        expect("Book flights next week", title: "Book flights", due: date(2026, 10, 26), timed: false)
        expect("Gym tomorrow morning", title: "Gym", due: date(2026, 10, 24, 9), timed: true, category: "health")
        expect("Email Tom about the venue #wedding", title: "Email Tom about the venue", due: nil, timed: false, tags: ["Wedding", "Tom"])
        expect("Text Sarah at 7 tonight", title: "Text Sarah", due: date(2026, 10, 23, 19), timed: true, tags: ["Sarah"])
        expect("Pick up dry cleaning this afternoon", title: "Pick up dry cleaning", due: date(2026, 10, 23, 14), timed: true, category: "errands")
        expect("Call Mum at 10", title: "Call Mum", due: date(2026, 10, 24, 10), timed: true)
        expect("Renew passport by 5 November", title: "Renew passport", due: date(2026, 11, 5), timed: false)
        expect("Finish the model by Thursday evening", title: "Finish the model", due: date(2026, 10, 29, 18), timed: true)
        expect("Reply to Ana ASAP", title: "Reply to Ana", due: date(2026, 10, 23), timed: false, tags: ["Ana"])
        check("next Friday is a week on", QuickParse.weekday(6, prefix: "next", nextWeek: false,
              today: date(2026, 10, 27), calendar: calendar) == date(2026, 11, 6))
        check("shorthand expands", QuickParse.expandShorthand("ring dad tn at 5 p.m.") == "ring dad tonight at 5pm",
              QuickParse.expandShorthand("ring dad tn at 5 p.m."))

        // 3. Sorter answers into suggestions.
        let answer = """
        {"items":[
         {"title":"Book dentist","category":"health","kind":"task","date":"2026-10-27","time":"","endDate":"","endTime":"","location":"","reference":"","notes":"","flagged":false,"repeatType":"none","repeatHours":0,"repeatWeekdays":[],"repeatDay":0,"tags":[]},
         {"title":"Dinner at Carbone","category":"social","kind":"event","date":"2026-10-30","time":"19:30","endDate":"","endTime":"21:30","location":"181 Thompson St","reference":"AB12","notes":"Table for 4","flagged":false,"repeatType":"none","repeatHours":0,"repeatWeekdays":[],"repeatDay":0,"tags":["sam","Social"," "]},
         {"title":"Pay rent","category":"money","kind":"task","date":"","time":"","endDate":"","endTime":"","location":"","reference":"","notes":"","flagged":false,"repeatType":"monthly","repeatHours":0,"repeatWeekdays":[],"repeatDay":1,"tags":[]},
         {"title":"Ring the bank","category":"nonsense","kind":"task","date":"","time":"16:00","endDate":"","endTime":"","location":"","reference":"","notes":"","flagged":true,"repeatType":"none","repeatHours":0,"repeatWeekdays":[],"repeatDay":0,"tags":[]},
         {"title":"Hotel in London","category":"personal","kind":"event","date":"2026-11-03","time":"","endDate":"2026-11-06","endTime":"","location":"The Hoxton","reference":"","notes":"","flagged":false,"repeatType":"none","repeatHours":0,"repeatWeekdays":[],"repeatDay":0,"tags":[]},
         {"title":"  ","category":"work","kind":"task","date":"","time":"","endDate":"","endTime":"","location":"","reference":"","notes":"","flagged":false,"repeatType":"none","repeatHours":0,"repeatWeekdays":[],"repeatDay":0,"tags":[]}
        ]}
        """
        let decoded = try? JSONDecoder().decode(SortedDump.self, from: Data(answer.utf8))
        check("sorter answer decodes", decoded?.items.count == 6)
        if let decoded {
            let proposals = Sorter.proposals(from: decoded, categories: cats, source: .voice, now: now)
            check("blank entries dropped", proposals.count == 5, "\(proposals.count)")
            if proposals.count == 5 {
                check("date-only to-do", proposals[0].item.due == date(2026, 10, 27) && !proposals[0].item.hasTime)
                let dinner = proposals[1].item
                check("booking start and end", dinner.isEvent && dinner.due == date(2026, 10, 30, 19, 30)
                      && dinner.end == date(2026, 10, 30, 21, 30) && dinner.reference == "AB12", "\(String(describing: dinner.end))")
                check("repeat becomes standing reminder", proposals[2].repeats == .monthly(day: 1, hour: 9, minute: 0))
                let routine = proposals[2].makeRoutine(now: now)
                check("standing reminder starts 1 Nov", routine?.nextDue == date(2026, 11, 1, 9), "\(String(describing: routine?.nextDue))")
                check("unknown list falls back to Personal", proposals[3].item.categoryID == "personal")
                check("time with no day is today", proposals[3].item.due == date(2026, 10, 23, 16) && proposals[3].item.flagged)
                check("tags tidied", proposals[1].item.tagList == ["Sam"], "\(proposals[1].item.tagList)")
                let hotel = proposals[4].item
                check("multi-day booking", hotel.isEvent && hotel.end == date(2026, 11, 7) && hotel.isOn(date(2026, 11, 5))
                      && !hotel.isOn(date(2026, 11, 7)), "\(String(describing: hotel.end))")
            }
        }
        check("search finds tags", { () -> Bool in
            let tagged = AgendaStore(testing: AgendaData())
            var item = Item(title: "Respond", categoryID: "work")
            item.tagList = ["John"]
            tagged.add([item])
            return tagged.search("#john").count == 1 && tagged.tags.first?.name == "John" && tagged.items(tagged: "john").count == 1
        }())
        check("schema is valid JSON", JSONSerialization.isValidJSONObject(Sorter.schema))
        let prompt = Sorter.instructions(categories: cats, now: now, shared: true)
        check("instructions carry today's date", prompt.contains("2026-10-23") && prompt.contains("money"))
        let demoDump = Sorter.proposals(from: Demo.sampleDump(), categories: cats, source: .voice)
        check("demo dump sorts", demoDump.count == 6 && demoDump.contains { $0.repeats != nil })

        // 4. The list itself.
        let store = AgendaStore(testing: AgendaData())
        var late = Item(title: "Return jacket", categoryID: "errands")
        late.due = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))
        var timed = Item(title: "Send memo", categoryID: "work")
        timed.due = Date().addingTimeInterval(2 * 3600)
        timed.hasTime = true
        let someday = Item(title: "Read a book", categoryID: "personal")
        store.add([late, timed, someday])
        check("slipped list", store.overdue().map(\.title) == ["Return jacket"])
        check("anytime list", store.anytime.map(\.title) == ["Read a book"])
        store.moveToTomorrow([late.id])
        check("move to tomorrow", store.overdue().isEmpty && store.item(late.id)?.due.map(calendar.isDateInTomorrow) == true)
        store.setDone(timed.id, true)
        check("tick off", store.doneToday().count == 1 && store.openTasks.count == 2)

        var injection = Routine.mounjaroPreset(now: now)
        injection.nextDue = Date().addingTimeInterval(-600)
        store.upsertRoutine(injection)
        let afterDose = store.markRoutineDone(injection.id)
        check("dose logged and next one set", store.log.count == 1 && (afterDose?.nextDue ?? .distantPast) > Date())
        check("injection spot rotates", afterDose?.lastSite == "Tummy (left)" && afterDose?.suggestedSite == "Tummy (right)",
              afterDose?.suggestedSite ?? "")
        check("pen count goes down", afterDose?.dosesLeft == 3)

        // 5. Nudges stay within iOS's limit and say the right things.
        for n in 0..<80 {
            var item = Item(title: "Task \(n)", categoryID: "work")
            item.due = Date().addingTimeInterval(Double(n + 1) * 1800)
            item.hasTime = true
            store.add([item])
        }
        let plans = Nudges.plan(store: store, alarmsAllowed: false)
        check("nudges within the limit", plans.count <= Nudges.budget, "\(plans.count)")
        check("standing reminder nudges kept", plans.contains { $0.id.hasPrefix("routine-") })
        check("unique nudge ids", Set(plans.map(\.id)).count == plans.count)
        let tomorrowMorning = calendar.date(bySettingHour: 8, minute: 30, second: 0,
                                            of: calendar.date(byAdding: .day, value: 1, to: Date())!)!
        let morning = Nudges.morningText(store: store, at: tomorrowMorning)
        check("morning round-up written", morning?.title.hasPrefix("Today:") == true, morning?.title ?? "nil")

        // 6. Widget data and saving.
        let snapshot = store.makeSnapshot()
        let encoded = try? JSONEncoder().encode(snapshot)
        let back = encoded.flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
        check("widget data round trip", back?.rows.count == snapshot.rows.count && !snapshot.rows.isEmpty)
        let whole = try? JSONEncoder().encode(store.data)
        let reread = whole.flatMap { try? JSONDecoder().decode(AgendaData.self, from: $0) }
        check("everything saves and loads", reread?.items.count == store.data.items.count && reread?.routines.count == 1)
        let drop = SharedDrop(text: "Your reservation at Carbone is confirmed", link: "https://example.com")
        let dropBack = (try? JSONEncoder().encode(drop)).flatMap { try? JSONDecoder().decode(SharedDrop.self, from: $0) }
        check("shared item round trip", dropBack?.text == drop.text)

        // 7. Words.
        check("when: today with time", DateWords.short(Date().addingTimeInterval(60), hasTime: false) == "Today")
        check("ordinals", RoutineSchedule.ordinal(1) == "1st" && RoutineSchedule.ordinal(22) == "22nd"
              && RoutineSchedule.ordinal(13) == "13th")

        let allPassed = results.allSatisfy { $0["ok"] as? Bool == true }
        let report: [String: Any] = ["result": allPassed ? "all passed" : "failed", "checks": results]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("selftest.json")
            try? data.write(to: url)
        }
        return true
    }
}
