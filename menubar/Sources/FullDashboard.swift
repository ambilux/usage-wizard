import SwiftUI
import ServiceManagement
import Charts
import AppKit

/// The big window: charts on top, suggestions below, sessions at the bottom.
final class FullDashboardWindow: NSObject {
    static let shared = FullDashboardWindow()
    private var window: NSWindow?

    /// Closes the small menu bar panel (it would otherwise stay open next to the big window).
    static func closeMenuPanel(except keep: NSWindow? = nil) {
        if let key = NSApp.keyWindow, key !== keep, key !== shared.window { key.close() }
        for w in NSApp.windows where w !== keep && w !== shared.window
            && w.isVisible && String(describing: type(of: w)).contains("MenuBarExtra") {
            w.close()
        }
    }

    /// Opens the big window; `settings: true` opens it on the settings page (from the panel's settings).
    func show(settings: Bool = false) {
        Self.closeMenuPanel()
        DashboardState.shared.showSettings = settings
        if window == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
            win.title = "Usage Wizard"
            win.titlebarAppearsTransparent = true
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: FullDashboardView().environmentObject(UsageStore.shared))
            win.center()
            window = win
        }
        UsageStore.shared.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Which page the big window shows; set from outside so the panel can open it on the settings page.
final class DashboardState: ObservableObject {
    static let shared = DashboardState()
    @Published var showSettings = false
}

struct FullDashboardView: View {
    @EnvironmentObject var store: UsageStore
    @ObservedObject private var state = DashboardState.shared
    private var showSettings: Bool { state.showSettings }
    @AppStorage("limitMode") private var limitMode = "recommended"
    @AppStorage("customLimit") private var customLimit = Advisor.recommendedHigh
    private var limit: Int { limitMode == "custom" ? customLimit : Advisor.recommendedHigh }

    var body: some View {
        if showSettings { settingsPage } else { dashboard }
    }

    /// Settings replace the dashboard content (instead of a small popover)
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Settings").font(.title2.weight(.semibold))
                    Spacer()
                    Button { state.showSettings = false } label: { Label("Back to dashboard", systemImage: "chevron.left") }
                        .keyboardShortcut(.cancelAction)
                }
                SettingsPanel()
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            }
            .frame(maxWidth: 620)
            .padding(24)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 820, minHeight: 600)
    }

    private var dashboard: some View {
        ScrollView {
            if let s = store.selected {
                VStack(alignment: .leading, spacing: 18) {
                    header(s)

                    // Key numbers
                    HStack(spacing: 12) {
                        StatCard(label: "Context now", value: short(s.lastCtx),
                                 sub: "\(CtxStatus(growth: s.growth).label) · +\(short(s.growth)) in chat", dot: CtxStatus(growth: s.growth).color)
                        CacheStatCard(session: s)
                        StatCard(label: "Responses", value: "\(s.turns.count)", sub: s.models.map(\.0).joined(separator: ", "))
                        StatCard(label: "Weighted tokens", value: short(s.weighted), sub: "raw \(short(s.total))")
                        StatCard(label: "Cache hit rate", value: "\(Int(s.cacheRate * 100))%", sub: "higher = cheaper")
                    }

                    // Charts
                    HStack(alignment: .top, spacing: 12) {
                        Card(title: "Context per response") { ContextChart(session: s, limit: limit).equatable().frame(height: 190) }
                        Card(title: "Weighted tokens per day · all sessions") { DailyChart(days: store.daily).equatable().frame(height: 190) }
                    }

                    // Suggestions + tools
                    HStack(alignment: .top, spacing: 12) {
                        Card(title: "Suggestions") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Advisor.tips(for: s)) { TipRow(tip: $0, session: s) }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        VStack(spacing: 12) {
                            Card(title: "Where the cost went") { CostBreakdown(parts: s.weightedParts) }
                            Card(title: "Top tools") { ToolBars(tools: s.tools) }
                        }
                        .frame(width: 300)
                    }

                    Card(title: "Sessions") { SessionList() }
                }
                .padding(24)
                .padding(.top, 8)
            } else {
                Text("No sessions found in ~/.claude/projects.").foregroundStyle(.secondary).padding(40)
            }
        }
        .frame(minWidth: 820, minHeight: 600)
    }

    private func header(_ s: Session) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.title2.weight(.semibold))
                Text("\(s.project) · started \(s.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(en)))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SessionPicker().frame(width: 280)
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Reload")
            Button { state.showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
        }
    }
}

/// Settings behind the gear button: a full page in the dashboard window, inline in the menu bar panel.
struct SettingsPanel: View {
    @State private var autoDelete = Handoffs.autoDelete
    @AppStorage("limitMode") private var limitMode = "recommended"
    @AppStorage("customLimit") private var customLimit = Advisor.recommendedHigh

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LimitSetting(mode: $limitMode, custom: $customLimit)
            Divider()
            CacheReminderSetting()
            Divider()
            MenuBarSetting()
            Divider()
            ChatMenuSetting()
            Divider()
            HandoffPromptSetting()
            Divider()
            CompactPromptSetting()
            Divider()
            LoginItemSetting()
            Divider()
            Toggle("Move handoff files to the Trash once the new chat has used them", isOn: $autoDelete)
                .onChange(of: autoDelete) { _, v in Handoffs.autoDelete = v }
            Text("Used = the new chat got the handoff and Claude answered. Files stay recoverable in the Trash.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Components

/// How the chat menu at the top of the panel lists chats.
struct ChatMenuSetting: View {
    @AppStorage("chatMenuFolders") private var folders = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Chat menu")
                Spacer()
                Picker("", selection: $folders) {
                    Text("Folders").tag(true)
                    Text("One list").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Text(folders ? "Chats grouped by project folder in a list below the chat button. Folders with the "
                           + "current chat or a warm cache open by themselves; click a folder to open or close it."
                         : "All chats in one list, newest first.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// When the "Time for a new chat" reminder comes. Stored as growth above the chat's start (that is what
/// a new chat saves), shown as total context (typical start + growth) because that is the number users see.
struct LimitSetting: View {
    @Binding var mode: String
    @Binding var custom: Int
    private var value: Int { mode == "custom" ? custom : Advisor.recommendedHigh }
    private func total(_ growth: Int) -> String { "≈" + short(Advisor.typicalStart + growth) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("New-chat reminder")
                Spacer()
                Picker("", selection: $mode) {
                    Text("Recommended").tag("recommended")
                    Text("Custom").tag("custom")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            // The slider only shows for Custom; Recommended is a fixed value
            if mode == "custom" {
                HStack {
                    KnobSlider(value: Binding(get: { Double(value) }, set: { custom = Int($0) }),
                               range: Double(Advisor.customRange.lowerBound)...Double(Advisor.customRange.upperBound),
                               step: 10_000)
                    Text(total(value)).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
            }
            Text("Reminder at \(total(value)) context (a new chat starts at ≈\(short(Advisor.typicalStart)), so +\(short(value)) of chat). "
                 + "Yellow hint at \(total(value * 6 / 10))."
                 + (mode == "custom" ? "" : " Recommended: a good balance of cost and precision."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How many minutes before the prompt cache expires the "Cache expires soon" reminder comes (Off = none).
/// Presets in the dropdown; "Custom" shows a field for your own number of minutes (1–55).
struct CacheReminderSetting: View {
    @AppStorage(Notifier.cacheLeadKey) private var lead = 5
    @AppStorage("cacheLeadCustom") private var isCustom = false
    @State private var typed = 5
    private let range = Notifier.cacheLeadRange
    private static let customTag = -1

    private var custom: Bool { lead > 0 && (isCustom || !Notifier.cacheLeadPresets.contains(lead)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Cache reminder")
                Spacer()
                if custom {
                    TextField("", value: $typed, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing).monospacedDigit()
                        .frame(width: 44)
                        .onChange(of: typed) { _, v in if v != lead { apply(v, custom: true) } }
                    Text("min").foregroundStyle(.secondary)
                }
                Picker("", selection: Binding(
                    get: { lead == 0 ? 0 : (custom ? Self.customTag : lead) },
                    set: { $0 == Self.customTag ? apply(lead > 0 ? lead : 5, custom: true) : apply($0, custom: false) })) {
                    Text("Off").tag(0)
                    Divider()
                    ForEach(Notifier.cacheLeadPresets, id: \.self) { Text("\($0) min").tag($0) }
                    Divider()
                    Text("Custom").tag(Self.customTag)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            .onAppear { typed = max(lead, range.lowerBound) }
            Text(lead == 0
                 ? "No reminder before the cache expires."
                 : "Notifies \(lead) min before the cache of a big chat (yellow or red) expires. "
                   + "Reply before then and the context stays cheap; after that it has to be written to the cache again."
                   + (custom ? " Type any value from \(range.lowerBound) to \(range.upperBound) min." : ""))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Clamp, store and re-plan the pending reminders right away.
    private func apply(_ minutes: Int, custom: Bool) {
        isCustom = custom && minutes > 0
        lead = minutes <= 0 ? 0 : min(max(minutes, range.lowerBound), range.upperBound)
        if lead > 0 { typed = lead }
        Notifier.shared.scheduleCacheReminders(UsageStore.shared.sessions)
    }
}

/// What the menu bar shows: symbol and/or the current context number.
struct MenuBarSetting: View {
    @AppStorage(MenuBarStyle.modeKey) private var mode = "both"
    @AppStorage(MenuBarStyle.symbolKey) private var symbol = MenuBarStyle.defaultSymbol

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Menu bar")
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(MenuBarStyle.modes, id: \.tag) { Text($0.label).tag($0.tag) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            if mode != "number" {
                HStack {
                    Text("Icon").foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $symbol) {
                        ForEach(MenuBarStyle.symbols, id: \.name) { o in
                            Label { Text(o.label) } icon: { MenuBarStyle.icon(o.name) }.tag(o.name)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
            }
            Text(mode == "icon"
                 ? "Only the icon – the context size isn't visible, e.g. when you share your screen."
                 : "The number is the context size of your latest chat.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Own texts for the two handoff prompts that are copied for you: "Move to new chat" (old chat writes
/// the handoff) and "Open new chat" (new chat reads it). "{file}" stands for the handoff path.
struct HandoffPromptSetting: View {
    @AppStorage(Prompts.customKey) private var useCustom = false
    @AppStorage(Prompts.writeKey) private var write = ""
    @AppStorage(Prompts.continueKey) private var cont = ""
    @State private var which = "write"

    private var text: Binding<String> {
        which == "write" ? $write : $cont
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Handoff prompts")
                Spacer()
                Picker("", selection: Binding(get: { useCustom }, set: { on in
                    useCustom = on
                    // Start from the default text so it only needs tweaking
                    if on && write.isEmpty { write = Prompts.defaultWrite }
                    if on && cont.isEmpty { cont = Prompts.defaultContinue }
                })) {
                    Text("Default").tag(false)
                    Text("Custom").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if useCustom {
                Picker("", selection: $which) {
                    Text("Old chat").tag("write")
                    Text("New chat").tag("continue")
                }
                .pickerStyle(.segmented).labelsHidden()
                TextEditor(text: text)
                    .font(.caption)
                    .frame(height: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Text("\(Prompts.placeholder) = path of the handoff file")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { text.wrappedValue = which == "write" ? Prompts.defaultWrite : Prompts.defaultContinue }
                        .controlSize(.small)
                        .help("Put the default text back into this prompt")
                }
            }
            Text(useCustom
                 ? (which == "write"
                    ? "Copied when you click \"Move to new chat\". Without \(Prompts.placeholder) the path is added at the end."
                    : "Sent to the new chat by \"Open new chat\" (after the automatic rename line). Without \(Prompts.placeholder) the path is added at the end.")
                 : "The texts copied for \"Move to new chat\" and \"Open new chat\". Choose Custom to use your own.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Own focus note for "Compact instead". Pasted after /compact as one line; empty = plain /compact.
struct CompactPromptSetting: View {
    @AppStorage(Prompts.compactCustomKey) private var useCustom = false
    @AppStorage(Prompts.compactKey) private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Compact prompt")
                Spacer()
                Picker("", selection: Binding(get: { useCustom }, set: { on in
                    useCustom = on
                    // First time: start from the default note so it only needs tweaking.
                    // Later an empty note stays empty (that is plain /compact on purpose).
                    if on && UserDefaults.standard.object(forKey: Prompts.compactKey) == nil { note = Prompts.defaultCompactNote }
                })) {
                    Text("Default").tag(false)
                    Text("Custom").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if useCustom {
                TextEditor(text: $note)
                    .font(.caption)
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Text("Empty = plain /compact")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { note = Prompts.defaultCompactNote }
                        .controlSize(.small)
                        .help("Put the default note back")
                }
            }
            Text(useCustom
                 ? "Copied as \"/compact <your note>\" when you click \"Compact instead\". Tell the summary what to keep and what to drop; line breaks become spaces."
                 : "\"Compact instead\" copies /compact with a note: keep goal, decisions, what didn't work, next step and file paths; drop code and logs. Choose Custom to write your own.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Start at login" via SMAppService: the app shows up in System Settings → General → Login Items
/// like any other app, needs no extra permission, and can be switched off there as well.
struct LoginItemSetting: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Start at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: set))
            Group {
                if let error {
                    Text(error)
                } else if status == .requiresApproval {
                    HStack(spacing: 4) {
                        Text("macOS needs your OK in Login Items.")
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(.link)
                    }
                } else {
                    Text("Opens Usage Wizard in the menu bar when you log in. Also listed in System Settings → General → Login Items.")
                }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { status = SMAppService.mainApp.status }   // may have been changed in System Settings
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't change it: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}

/// Slider with a white knob: the system knob is dark in dark mode and hard to see in the settings.
struct KnobSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    private let knob: CGFloat = 18

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width - knob, 1)
            let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.35)).frame(height: 4).padding(.horizontal, knob / 2)
                Capsule().fill(Color.accentColor).frame(width: w * frac, height: 4).padding(.leading, knob / 2)
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: w * frac)
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let f = min(max(Double((d.location.x - knob / 2) / w), 0), 1)
                let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                let v = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
                if v != value { value = v }
            })
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(value))"))
        .accessibilityAdjustableAction { dir in
            value = min(max(value + (dir == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

struct StatCard: View {
    let label: String, value: String, sub: String
    var dot: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
            HStack(spacing: 4) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(sub).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

/// Cache warm (live countdown) or cold, like the cache row in the menu bar panel.
/// Only this card ticks every second, so the rest of the dashboard isn't re-laid out.
struct CacheStatCard: View {
    let session: Session
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = (session.cacheExpires ?? .distantPast).timeIntervalSince(ctx.date)
            if left > 0 {
                StatCard(label: "Cache warm for", value: CacheRow.clock(left), sub: "replies stay cheap",
                         dot: left < 300 ? .orange : .green)
            } else {
                let rewrite = Int(Double(session.lastCtx) * (session.cacheTTL > 300 ? 2 : 1.25))
                StatCard(label: "Cache", value: "Cold", sub: "next reply rewrites ≈\(short(rewrite))", dot: .secondary)
            }
        }
        .help("Prompt cache of this chat. While warm, the context is read cheaply; once cold, the next reply writes it to the cache again.")
    }
}

/// Equatable so the chart is only redrawn when its data changes, not on every parent update.
struct ContextChart: View, Equatable {
    let session: Session
    let limit: Int      // reminder point (growth above start); part of == so the /clear line moves when changed
    @State private var selected: Int?

    static func == (a: Self, b: Self) -> Bool {
        a.session.id == b.session.id && a.session.turns.count == b.session.turns.count && a.limit == b.limit
    }

    /// At most ~200 points: long chats otherwise draw hundreds of marks per frame
    private var points: [(i: Int, ctx: Int)] {
        let n = session.turns.count, step = max(1, n / 200)
        var p = stride(from: 0, to: n, by: step).map { ($0 + 1, session.turns[$0].ctx) }
        if let last = session.turns.last, p.last?.0 != n { p.append((n, last.ctx)) }
        return p
    }

    var body: some View {
        Chart {
            ForEach(points, id: \.i) { i, ctx in
                AreaMark(x: .value("Response", i), y: .value("Context", ctx))
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                LineMark(x: .value("Response", i), y: .value("Context", ctx))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if session.peakGrowth >= limit * 6 / 10 {
                RuleMark(y: .value("Limit", session.baseCtx + limit))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("/clear zone").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let sel = selected, sel >= 1, sel <= session.turns.count {
                let t = session.turns[sel - 1]
                RuleMark(x: .value("Response", sel))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Tooltip(lines: ["Response \(sel) · \(t.ts.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(en)))",
                                        "Context \(short(t.ctx)) · Output \(short(t.out))"])
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let n = v.as(Int.self) { Text(short(n)) } }
            }
        }
    }
}

struct DailyChart: View, Equatable {
    let days: [(day: Date, tokens: Int)]
    @State private var selected: String?

    static func == (a: Self, b: Self) -> Bool {
        a.days.count == b.days.count && zip(a.days, b.days).allSatisfy { $0.day == $1.day && $0.tokens == $1.tokens }
    }

    private func label(_ d: Date) -> String {
        d.formatted(Date.FormatStyle().month(.abbreviated).day().locale(en))
    }

    var body: some View {
        // Only days with activity, as categories, so gaps between months don't squash the bars
        let recent = Array(days.suffix(14))
        Chart {
            ForEach(recent, id: \.day) { d in
                BarMark(x: .value("Day", label(d.day)), y: .value("Tokens", d.tokens), width: .ratio(0.6))
                    .foregroundStyle(Color.accentColor.opacity(selected == nil || selected == label(d.day) ? 1 : 0.5))
                    .cornerRadius(4)
            }
            if let sel = selected, let d = recent.first(where: { label($0.day) == sel }) {
                RuleMark(x: .value("Day", sel))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Tooltip(lines: [sel, "\(short(d.tokens)) weighted tokens"])
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let n = v.as(Int.self) { Text(short(n)) } }
            }
        }
    }
}

struct Tooltip: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 1) { ForEach(lines, id: \.self) { Text($0) } }
            .font(.caption2)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background).shadow(radius: 2))
    }
}

struct CostBreakdown: View {
    let parts: [(String, Int)]
    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.1 })
        VStack(alignment: .leading, spacing: 6) {
            ForEach(parts.sorted { $0.1 > $1.1 }, id: \.0) { name, v in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(name).font(.caption)
                        Spacer()
                        Text("\(Int((Double(v) / Double(total) * 100).rounded()))%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                            .frame(width: max(2, g.size.width * Double(v) / Double(total)))
                    }
                    .frame(height: 5)
                }
            }
            Text("Share of weighted tokens. Cache reads are cheap, writes and output are not.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ToolBars: View {
    let tools: [String: Int]
    var body: some View {
        let top = Array(tools.sorted { $0.value > $1.value }.prefix(6))
        let mx = Double(top.first?.value ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            if top.isEmpty { Text("No tool calls.").font(.caption).foregroundStyle(.secondary) }
            ForEach(top, id: \.key) { k, v in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(k.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " › "))
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(v)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                            .frame(width: max(2, g.size.width * Double(v) / mx))
                    }
                    .frame(height: 5)
                }
            }
        }
    }
}

enum SessionSort: String, CaseIterable, Identifiable {
    case recent = "Recent", weighted = "Weighted", responses = "Responses", peak = "Peak context"
    var id: String { rawValue }
    var help: String {
        switch self {
        case .recent: return "Newest chats first."
        case .weighted: return "Highest usage first, in weighted tokens (each token counted by what it costs)."
        case .responses: return "Chats with the most replies first."
        case .peak: return "Chats with the biggest context first."
        }
    }
}

/// Chats grouped by the folder they run in (their working directory).
struct FolderGroup: Identifiable {
    let id: String          // the folder path (or the project name when the log has no cwd)
    var name: String
    var sessions: [Session]
    var latest: Date { sessions.map(\.modified).max() ?? .distantPast }
    var weighted: Int { sessions.reduce(0) { $0 + $1.weighted } }
    var isLive: Bool { sessions.contains { $0.isLive } }
    var cacheWarm: Bool { sessions.contains { $0.cacheWarm } }

    /// Keeps the order of `sessions` inside each group; groups with the newest activity come first.
    /// Two folders with the same name are told apart by their parent folder.
    static func make(_ sessions: [Session]) -> [FolderGroup] {
        var order: [String] = [], byKey: [String: [Session]] = [:]
        for s in sessions {
            let k = s.cwd ?? s.project
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(s)
        }
        var groups = order.map { FolderGroup(id: $0, name: byKey[$0]![0].project, sessions: byKey[$0]!) }
        let dupes = Dictionary(grouping: groups, by: \.name).filter { $0.value.count > 1 }.keys
        for i in groups.indices where dupes.contains(groups[i].name) {
            let u = URL(fileURLWithPath: groups[i].id)
            groups[i].name = u.deletingLastPathComponent().lastPathComponent + "/" + u.lastPathComponent
        }
        return groups.sorted { $0.latest > $1.latest }
    }
}

struct SessionList: View {
    @EnvironmentObject var store: UsageStore
    @AppStorage("sessionSort") private var sort: SessionSort = .recent
    @AppStorage("groupByFolder") private var grouped = true
    @AppStorage("collapsedFolders") private var collapsedRaw = ""

    static let helpResponses = "How many replies Claude has given in this chat."
    static var helpPeak: String { "The most Claude had to read for one reply in this chat. Red = above your new-chat reminder point (Settings)." }
    static let helpWeighted = "Total usage in weighted tokens: each token counted by what it costs (output 5×, cache write 1.25–2×, cache read a fraction). Closest to how much of your limit the chat used."

    private var sorted: [Session] {
        switch sort {
        case .recent: return store.sessions   // already newest first
        case .weighted: return store.sessions.sorted { $0.weighted > $1.weighted }
        case .responses: return store.sessions.sorted { $0.turns.count > $1.turns.count }
        case .peak: return store.sessions.sorted { $0.peakCtx > $1.peakCtx }
        }
    }

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }
    private func toggle(_ id: String) {
        var c = collapsed
        if c.contains(id) { c.remove(id) } else { c.insert(id) }
        collapsedRaw = c.sorted().joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle("Group by folder", isOn: $grouped)
                    .toggleStyle(.checkbox)
                    .hoverTip("Show chats under the project folder they run in.")
                Spacer()
                Text("Sort by").foregroundStyle(.secondary)
                SortBar(sort: $sort)
            }
            .padding(.bottom, 8)
            HStack {
                Color.clear.frame(width: 6, height: 6)
                Text("Chat")
                Spacer()
                Text("Responses").hoverTip(Self.helpResponses).frame(width: 70, alignment: .trailing)
                Text("Peak context").hoverTip(Self.helpPeak).frame(width: 80, alignment: .trailing)
                Text("Weighted").hoverTip(Self.helpWeighted).frame(width: 60, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.bottom, 4)
            Divider()
            if grouped {
                ForEach(FolderGroup.make(sorted)) { g in
                    let open = !collapsed.contains(g.id)
                    Button { toggle(g.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(open ? 90 : 0))
                                .frame(width: 10)
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(g.name).fontWeight(.semibold).lineLimit(1)
                            Text("\(g.sessions.count) chat\(g.sessions.count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                            if g.isLive { Circle().fill(Color.green).frame(width: 6, height: 6) }
                            Spacer()
                            Text(short(g.weighted)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    if open {
                        ForEach(g.sessions) { row($0, showProject: false).padding(.leading, 16) }
                    }
                }
            } else {
                ForEach(sorted) { row($0, showProject: true) }
            }
            Text("● green = chat was active in the last 15 min · red peak = above your new-chat reminder point")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.top, 6)
        }
    }

    private func row(_ s: Session, showProject: Bool) -> some View {
        let isSel = s.id == store.selected?.id
        return Button { store.select(s.id) } label: {
            HStack {
                Circle().fill(s.isLive ? Color.green : Color.clear).frame(width: 6, height: 6)
                Text(s.title).lineLimit(1)
                if showProject { Text(s.project).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Text("\(s.turns.count)").foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                Text(short(s.peakCtx))
                    .foregroundStyle(CtxStatus(growth: s.peakGrowth) == .high ? Color.red : Color.secondary)
                    .frame(width: 80, alignment: .trailing)
                Text(short(s.weighted)).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            .font(.callout)
            .padding(.vertical, 7).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSel ? Color.accentColor.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Segmented control drawn by hand, so each option can explain itself on hover
/// (a system segmented Picker has no per-segment hover).
struct SortBar: View {
    @Binding var sort: SessionSort
    var body: some View {
        HStack(spacing: 2) {
            ForEach(SessionSort.allCases) { o in
                let on = o == sort
                Button { sort = o } label: {
                    Text(o.rawValue)
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(on ? Color(nsColor: .controlColor) : .clear)
                            .shadow(color: .black.opacity(on ? 0.2 : 0), radius: 0.5, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTip(o.help)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
    }
}

/// Small explanation bubble above a view while the mouse rests on it. Used instead of `.help`,
/// whose system tooltips don't show reliably in this window.
struct HoverTip: ViewModifier {
    let text: String
    @State private var show = false
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    let w = DispatchWorkItem { show = true }
                    pending = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
                } else {
                    show = false
                }
            }
            .popover(isPresented: $show, arrowEdge: .top) {
                Text(text)
                    .font(.callout)
                    .frame(width: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
    }
}

extension View {
    func hoverTip(_ text: String) -> some View { modifier(HoverTip(text: text)) }
}

