import Foundation

struct Tip: Identifiable {
    enum Level: Int { case high = 0, medium, info, good }
    let id = UUID()
    let level: Level
    let title: String
    let text: String
    var actions: [ClaudeAction] = []
}

enum Advisor {
    // Rules of thumb, not official limits. Measured as growth above the chat's starting size
    // (s.growth), because every chat starts at ~65k anyway and a new chat only saves what came after.
    // Recommended: reminder at +100k, "getting big" hint at +60k. Users can set their own reminder
    // point in the dashboard settings; the hint then stays at 60 % of it.
    static let recommendedHigh = 100_000
    /// Typical context of a fresh chat (system prompt, tools, CLAUDE.md); only used to show totals
    static let typicalStart = 60_000
    static let customRange = 40_000...440_000   // shown as ≈100k…≈500k total
    static var highGrowth: Int {
        let d = UserDefaults.standard
        guard d.string(forKey: "limitMode") == "custom" else { return recommendedHigh }
        let v = d.integer(forKey: "customLimit")
        return v == 0 ? recommendedHigh : min(max(v, customRange.lowerBound), customRange.upperBound)
    }
    static var warnGrowth: Int { highGrowth * 6 / 10 }

    static func tips(for s: Session) -> [Tip] {
        var t: [Tip] = []
        let handoff = Handoffs.written(for: s) != nil

        if handoff {
            t.append(Tip(level: .high, title: "Handoff ready – step 2",
                         text: "This chat's handoff is written. Open the new chat – it checks the handoff and asks before it starts.",
                         actions: [.openHandoffChat]))
        }

        // 1. Context size. Big context = every reply resends it, cache expires on pauses,
        //    and very long chats get less precise.
        if s.growth >= highGrowth {
            if !handoff {
                t.append(Tip(level: .high, title: "Time for a new chat (\(short(s.lastCtx)) context)",
                             text: "Long chats get less precise and every reply resends all of it. "
                                 + "Move on: this chat writes a handoff, then the new chat picks it up.",
                             actions: [.moveToNewChat, .compact]))
            }
        } else if s.growth >= warnGrowth {
            if !handoff {
                t.append(Tip(level: .medium, title: "Chat is getting big (\(short(s.lastCtx)) context)",
                             text: "Still fine. At \(short(s.baseCtx + highGrowth)) you'll get a reminder. Want to move earlier, e.g. at a good stopping point?",
                             actions: [.moveToNewChat]))
            }
        }

        if s.turns.count >= 120 && s.growth < warnGrowth {
            t.append(Tip(level: .info, title: "Long session (\(s.turns.count) responses)",
                         text: "One chat per task keeps context small and answers precise."))
        }

        // 2. Model choice
        let opus = s.turns.filter { $0.model.contains("opus") }.count
        let outs = s.turns.map(\.out).sorted()
        let median = outs.isEmpty ? 0 : outs[outs.count / 2]
        if s.turns.count >= 15, Double(opus) / Double(s.turns.count) > 0.8, median < 400 {
            t.append(Tip(level: .info, title: "Opus for small steps",
                         text: "Typical response is only \(median) tokens. For routine work, Sonnet or a lower effort level is often enough (model picker in Claude)."))
        }

        // 3. Cache expired after long pauses
        let gaps = zip(s.turns, s.turns.dropFirst()).filter { a, b in
            b.ts.timeIntervalSince(a.ts) > 3600 && b.cw > 20_000
        }.count
        if gaps > 0 {
            t.append(Tip(level: .info, title: "Cache expired \(gaps)×",
                         text: "After a pause of over 1 h the whole context is billed again at write price. "
                             + "Before a long break in a big chat, move to a new chat first."))
        }

        // 4. Screenshots are expensive
        let shots = s.tools.filter { $0.key.lowercased().contains("screen") }.values.reduce(0, +)
        if shots >= 8 {
            t.append(Tip(level: .info, title: "\(shots) screenshots",
                         text: "Images take a lot of context. Ask Claude to read values as text where possible (console, logs)."))
        }

        // 5. No CLAUDE.md
        if let cwd = s.cwd, FileManager.default.fileExists(atPath: cwd),
           !FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent("CLAUDE.md")) {
            t.append(Tip(level: .info, title: "No CLAUDE.md in \"\(s.project)\"",
                         text: "A short CLAUDE.md saves re-exploring the project in every new chat – and makes fresh chats cheap.",
                         actions: [.createClaudeMd]))
        }

        if t.isEmpty {
            t.append(Tip(level: .good, title: "All good", text: "Context is small, no notable patterns."))
        }
        return t.sorted { $0.level.rawValue < $1.level.rawValue }
    }
}
