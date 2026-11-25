import Foundation
import AppKit
import CoreServices

// MARK: - Data model

struct Turn {
    let ts: Date
    let inp: Int, cw: Int, cr: Int, out: Int
    let cw1h: Int               // part of cw written with the 1-hour TTL
    let model: String
    var ctx: Int { inp + cw + cr }

    /// Tokens weighted by what they cost, in "normal input token" units.
    /// Multipliers from Anthropic's pricing (relative to base input price):
    /// cache write 1.25× (5 min) / 2× (1 h), output 5×, cache read depends on model.
    var weighted: Double {
        let readMult: Double = model.hasPrefix("fable-5-2") || model.hasPrefix("fable-5-1")
            || model.hasPrefix("mythos-5-2") || model.hasPrefix("mythos-5-1") ? 0.025
            : model.hasPrefix("opus-5-5") || model.hasPrefix("sonnet-5-5") ? 0.05
            : 0.1
        let cw5m = cw - cw1h
        return Double(inp) + Double(cw5m) * 1.25 + Double(cw1h) * 2 + Double(cr) * readMult + Double(out) * 5
    }
}

struct Session: Identifiable {
    let id: String              // path of the log file
    var title: String
    var project: String
    var cwd: String?
    var turns: [Turn]
    var tools: [String: Int]
    var cost: Double?
    /// Last message in the chat (yours or Claude's). Not the log file's time: Claude touches the log when you
    /// click a chat, but not when you click back to one already loaded, so following clicks would be unreliable.
    var modified: Date
    var prompts: [String] = []       // only user prompts that mention .handoffs/, oldest first
    var hasReply = false              // Claude has answered with text (reply itself is not kept)

    var start: Date { turns.first?.ts ?? modified }
    var lastCtx: Int { turns.last?.ctx ?? 0 }
    var peakCtx: Int { turns.map(\.ctx).max() ?? 0 }
    /// What every chat already costs on its first call (system prompt, tool + connector definitions,
    /// CLAUDE.md). A new chat can't get below this, so warnings only count growth on top of it.
    var baseCtx: Int { turns.first?.ctx ?? 0 }
    var growth: Int { max(0, lastCtx - baseCtx) }
    var peakGrowth: Int { max(0, peakCtx - baseCtx) }
    var output: Int { turns.reduce(0) { $0 + $1.out } }
    var total: Int { turns.reduce(0) { $0 + $1.ctx + $1.out } }
    var weighted: Int { Int(turns.reduce(0.0) { $0 + $1.weighted }) }
    /// Where the weighted cost came from
    var weightedParts: [(String, Int)] {
        var p = (inp: 0.0, cw: 0.0, cr: 0.0, out: 0.0)
        for t in turns {
            let w = t.weighted
            let out = Double(t.out) * 5, inp = Double(t.inp)
            let cw = Double(t.cw - t.cw1h) * 1.25 + Double(t.cw1h) * 2
            p.out += out; p.inp += inp; p.cw += cw; p.cr += w - out - inp - cw
        }
        return [("Cache write", Int(p.cw)), ("Output", Int(p.out)), ("Cache read", Int(p.cr)), ("New input", Int(p.inp))]
    }
    var cacheRate: Double {
        let inp = turns.reduce(0) { $0 + $1.ctx }
        return inp == 0 ? 0 : Double(turns.reduce(0) { $0 + $1.cr }) / Double(inp)
    }
    var models: [(String, Int)] {
        Dictionary(grouping: turns, by: \.model).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
    }
    var isLive: Bool { Date().timeIntervalSince(modified) < 15 * 60 }
    /// Prompt cache still warm (continuing is cheap); ♨ in the chat menu
    var cacheWarm: Bool { (cacheExpires ?? .distantPast) > Date() }

    /// The prompt cache lives 5 min after its last use, or 1 h if Claude Code wrote it with the
    /// 1-hour TTL (detected from the latest cache write).
    var cacheTTL: TimeInterval { (turns.last { $0.cw > 0 }?.cw1h ?? 0) > 0 ? 3600 : 300 }
    var cacheExpires: Date? { turns.last.map { $0.ts.addingTimeInterval(cacheTTL) } }
}

// MARK: - Log parser (reads only ~/.claude/projects)

enum LogParser {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// One session log file, read incrementally: after the first full read, only the bytes
/// appended since last time are parsed (logs only ever grow), so refreshing a big live
/// session costs almost nothing.
final class LogFile {
    let url: URL
    private var offset: UInt64 = 0
    private var order: [String] = []
    private var turns: [String: Turn] = [:]
    private var tools: [String: Int] = [:]
    private var title: String?
    private var cwd: String?
    private var cost: Double?
    private var prompts: [String] = []
    private var hasReply = false
    private var lastMessage: Date?
    private(set) var modified: Date = .distantPast
    private(set) var session: Session?

    init(url: URL) { self.url = url }

    func update(modified: Date, size: UInt64) -> Session? {
        if modified == self.modified, size == offset { return session }
        if size < offset { reset() }                       // file was rewritten -> start over
        if size > offset, let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            try? fh.seek(toOffset: offset)
            let data = (try? fh.readToEnd()) ?? Data()
            if let nl = data.lastIndex(of: 0x0A) {         // only complete lines; the rest waits
                for line in data[data.startIndex...nl].split(separator: 0x0A) { consume(line) }
                offset += UInt64(data.distance(from: data.startIndex, to: nl) + 1)
            }
        }
        self.modified = modified
        session = build()
        return session
    }

    private func reset() {
        offset = 0; order = []; turns = [:]; tools = [:]; title = nil; cwd = nil; cost = nil
        prompts = []; hasReply = false; lastMessage = nil
    }

    private func consume(_ line: Data.SubSequence) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
        let type = obj["type"] as? String
        if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
        if type == "assistant" || (type == "user" && obj["isMeta"] as? Bool != true),
           let tsStr = obj["timestamp"] as? String, let ts = LogParser.iso.date(from: tsStr) {
            lastMessage = max(lastMessage ?? ts, ts)
        }
        if type == "custom-title" { title = obj["customTitle"] as? String }
        if type == "cost-state" { cost = obj["totalCostUSD"] as? Double }
        if type == "user", obj["isMeta"] as? Bool != true, let msg = obj["message"] as? [String: Any] {
            var blocks: [String] = []
            if let c = msg["content"] as? String { blocks = [c] }
            else if let arr = msg["content"] as? [[String: Any]],
                    !arr.contains(where: { $0["type"] as? String == "tool_result" }) {
                blocks = arr.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            }
            let text = blocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasPrefix("[Request interrupted") }
                .joined(separator: "\n")
            // Only prompts that name a handoff file are kept (needed to detect a used handoff);
            // everything else you typed is not held in memory.
            if text.contains(".handoffs/") { prompts.append(text) }
        }
        guard type == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let model = msg["model"] as? String, model != "<synthetic>",
              let tsStr = obj["timestamp"] as? String,
              let ts = LogParser.iso.date(from: tsStr) else { return }

        if let content = msg["content"] as? [[String: Any]] {
            for b in content where b["type"] as? String == "tool_use" {
                tools[b["name"] as? String ?? "?", default: 0] += 1
            }
            let t = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { hasReply = true }
        }
        // One response is logged once per content block -> dedupe by ID
        let key = "\(msg["id"] as? String ?? UUID().uuidString)|\(obj["requestId"] as? String ?? "")"
        if turns[key] == nil { order.append(key) }
        turns[key] = Turn(ts: ts,
                          inp: usage["input_tokens"] as? Int ?? 0,
                          cw: usage["cache_creation_input_tokens"] as? Int ?? 0,
                          cr: usage["cache_read_input_tokens"] as? Int ?? 0,
                          out: usage["output_tokens"] as? Int ?? 0,
                          cw1h: (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0,
                          model: model.replacingOccurrences(of: "claude-", with: ""))
    }

    private func build() -> Session? {
        let list = order.compactMap { turns[$0] }
        guard !list.isEmpty else { return nil }
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? url.deletingLastPathComponent().lastPathComponent
        return Session(id: url.path,
                       title: title ?? String(url.deletingPathExtension().lastPathComponent.prefix(8)),
                       project: project, cwd: cwd, turns: list, tools: tools, cost: cost, modified: lastMessage ?? modified,
                       prompts: prompts, hasReply: hasReply)
    }
}

// MARK: - Store

final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var sessions: [Session] = []
    /// Weighted tokens per day across all sessions (oldest first); computed off the main thread
    @Published var daily: [(day: Date, tokens: Int)] = []
    private var lastSignature = ""
    private var lastPublish = Date.distantPast
    @Published var selectedID: String?
    @Published var followLatest = true

    private var files: [String: LogFile] = [:]
    private var timer: Timer?
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "usage.parse", qos: .utility)

    init() {
        refresh()
        startWatching()
        // Fallback only: keeps "live" dots and relative times fresh and catches anything the watcher missed.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.startWatching()
            self?.refresh()
        }
        timer?.tolerance = 30   // let macOS batch wake-ups (saves energy)
        // Opening the panel or the dashboard: read right away
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.refresh() }
    }

    /// Wakes the app only when Claude Code writes a log. macOS bundles the writes of one
    /// reply (latency 0.3 s), so a new message shows up almost at once. Each refresh
    /// only reads lines appended since the last one, so the short latency costs next to nothing.
    private func startWatching() {
        guard stream == nil, FileManager.default.fileExists(atPath: LogParser.root.path) else { return }
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in UsageStore.shared.refresh() }
        guard let s = FSEventStreamCreate(nil, callback, nil, [LogParser.root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) { stream = s } else { FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }

    var latest: Session? { sessions.first }
    var selected: Session? { sessions.first { $0.id == selectedID } ?? latest }

    func select(_ id: String?) {
        selectedID = id
        followLatest = (id == latest?.id)
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            var found: [Session] = []
            var seen = Set<String>()
            let projects = (try? fm.contentsOfDirectory(at: LogParser.root, includingPropertiesForKeys: nil)) ?? []
            for dir in projects {
                let list = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
                for f in list where f.pathExtension == "jsonl" {
                    let v = try? f.resourceValues(forKeys: Set(keys))
                    let file = self.files[f.path] ?? LogFile(url: f)
                    self.files[f.path] = file
                    seen.insert(f.path)
                    if let s = file.update(modified: v?.contentModificationDate ?? .distantPast,
                                           size: UInt64(v?.fileSize ?? 0)) {
                        found.append(s)
                    }
                }
            }
            self.files = self.files.filter { seen.contains($0.key) }   // logs deleted by Claude Code
            found.sort { $0.modified > $1.modified }
            // Only publish when something changed (or once a minute for "live" dots / relative times):
            // every publish redraws all charts, which made scrolling the dashboard stutter.
            // Deliberately not the file's modification time: a running chat writes its log every few seconds.
            let sig = found.map { "\($0.id)|\($0.turns.count)|\($0.title)|\($0.prompts.count)|\($0.hasReply)" }
                .joined(separator: "\n")
            if sig == self.lastSignature, Date().timeIntervalSince(self.lastPublish) < 60 { return }
            self.lastSignature = sig
            self.lastPublish = Date()
            let daily = Self.dailyTotals(found)
            DispatchQueue.main.async {
                self.sessions = found
                self.daily = daily
                Notifier.shared.check(found)
                Handoffs.cleanUpUsed(found)
                if self.followLatest || self.selectedID == nil || !found.contains(where: { $0.id == self.selectedID }) {
                    self.selectedID = found.first?.id
                }
            }
        }
    }

    private static func dailyTotals(_ sessions: [Session]) -> [(day: Date, tokens: Int)] {
        let cal = Calendar.current
        var d: [Date: Int] = [:]
        for s in sessions { for t in s.turns { d[cal.startOfDay(for: t.ts), default: 0] += Int(t.weighted) } }
        return d.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var todayWeighted: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return daily.last { $0.day == today }?.tokens ?? 0
    }
}

// MARK: - Formatting

func short(_ n: Int) -> String {
    let d = Double(n)
    let s: String
    switch d {
    case 1e9...: s = String(format: "%.1fB", d / 1e9)
    case 1e6...: s = String(format: "%.1fM", d / 1e6)
    case 1e3...: s = String(format: "%.0fk", d / 1e3)
    default: s = "\(n)"
    }
    return s
}
