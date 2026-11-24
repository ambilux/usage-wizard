import SwiftUI
import Charts
import AppKit

let en = Locale(identifier: "en_US")

@main
struct UsageWizardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(store)
        } label: {
            MenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Opening the app again while it runs (double-click in Finder, Spotlight …)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = PanelState.shared   // start listening before the panel opens for the first time
        // Check that notifications (and the app icon they show) work:
        // "/Applications/Usage Wizard.app/Contents/MacOS/UsageWizard" --test-notification
        if CommandLine.arguments.contains("--test-notification") {
            Notifier.shared.info("Test notification: notifications work.")
        }
    }

    /// Like other menu bar apps: launching it again just opens the small panel under its icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { MenuPanel.open() }
        return false
    }
}

/// Whether the small menu bar panel is showing (it becomes key when opened, resigns when closed)
final class PanelState: ObservableObject {
    static let shared = PanelState()
    @Published var isOpen = false
    /// Settings shown inside the panel. Reset right when the panel closes, so it always reopens on
    /// the usage view (an onChange in the hidden panel view doesn't fire reliably).
    @Published var showSettings = false
    /// Chat list (Chat menu: Folders) opened below the chat button in the panel
    @Published var chatListOpen = false
    private init() {
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let w = n.object as? NSWindow,
                      String(describing: type(of: w)).contains("MenuBarExtra") else { return }
                let open = name == NSWindow.didBecomeKeyNotification
                if self?.isOpen != open { self?.isOpen = open }
                if !open, self?.showSettings == true { self?.showSettings = false }
                if !open, self?.chatListOpen == true { self?.chatListOpen = false }
            }
        }
    }
}

enum MenuPanel {
    static var isOpen: Bool {
        NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("MenuBarExtra") }
    }

    /// MenuBarExtra has no API to open its panel, so click its status bar button.
    static func open() {
        guard !isOpen else { NSApp.activate(ignoringOtherApps: true); return }
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBarWindow") {
            if let button = findButton(in: w.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        for sub in view.subviews { if let b = findButton(in: sub) { return b } }
        return nil
    }
}

// MARK: - Status helpers

enum CtxStatus {
    case ok, growing, high
    /// `growth` = context added since the chat's first call (see Session.growth)
    init(growth: Int) {
        self = growth >= Advisor.highGrowth ? .high : growth >= Advisor.warnGrowth ? .growing : .ok
    }
    var color: Color { self == .high ? .red : self == .growing ? .orange : .green }
    var label: String { self == .high ? "Clear soon" : self == .growing ? "Getting big" : "Healthy" }
}

// MARK: - Menu bar icon

/// What the menu bar shows (Settings → Menu bar): the app's own pixel icons and/or the context number.
enum MenuBarStyle {
    static let modeKey = "menuBarMode", symbolKey = "menuBarSymbol"
    /// "both" = icon + context number, "icon" = icon only, "number" = number only
    static let modes: [(tag: String, label: String)] = [("both", "Icon + number"), ("icon", "Icon only"), ("number", "Number only")]
    /// Pixel icons drawn by icon/make_wizard.swift and bundled by build.sh
    /// (template images, tinted white or black like system symbols)
    static let images: [(tag: String, label: String, file: String)] = [
        ("wizard", "Wizard", "WizardMenu"), ("hat", "Hat", "HatMenu"), ("wand", "Wand", "WandMenu"),
    ]
    static let bundled: [String: NSImage] = {
        var d: [String: NSImage] = [:]
        for i in images {
            guard let img = Bundle.main.image(forResource: i.file) else { continue }
            let h: CGFloat = 18      // 36 px artwork = 18 pt at 2×, pixel for pixel
            img.size = NSSize(width: (img.size.width / img.size.height * h).rounded(), height: h)
            img.isTemplate = true
            d[i.tag] = img
        }
        return d
    }()

    static let symbols: [(name: String, label: String)] = {
        let list = images.filter { bundled[$0.tag] != nil }.map { ($0.tag, $0.label) }
        // A choice from an older version (system symbols were removed) goes back to the default
        if let saved = UserDefaults.standard.string(forKey: symbolKey), !list.contains(where: { $0.0 == saved }) {
            UserDefaults.standard.removeObject(forKey: symbolKey)
        }
        return list
    }()
    static let defaultSymbol = "wizard"

    /// Unknown or older choices (e.g. a removed system symbol) fall back to the wizard
    @ViewBuilder static func icon(_ name: String) -> some View {
        if let img = bundled[name] ?? bundled[defaultSymbol] { Image(nsImage: img) }
        else { Image(systemName: "wand.and.stars") }   // artwork missing in this build
    }
}

struct MenuLabel: View {
    // Observes the store itself: a value passed in from the App scene does not reliably
    // re-render the MenuBarExtra label, so the number could stay frozen.
    @ObservedObject var store: UsageStore
    @AppStorage(MenuBarStyle.modeKey) private var mode = "both"
    @AppStorage(MenuBarStyle.symbolKey) private var symbol = MenuBarStyle.defaultSymbol
    var body: some View {
        let ctx = store.latest?.lastCtx
        // Never leave the menu bar empty: "Number only" falls back to the icon until there is a number
        let showNumber = mode != "icon" && ctx != nil
        let showIcon = mode != "number" || ctx == nil
        HStack(spacing: 3) {
            if showIcon { MenuBarStyle.icon(symbol) }
            if showNumber, let ctx { Text(short(ctx)) }
        }
    }
}

// MARK: - Session picker (shared)

/// Chat menu at the top of the panel. Setting "Chat menu": Folders (default) – a list that opens below the
/// button, chats grouped by project folder, folders open and close on click – or One list, a plain menu. In the panel the list opens inline (a popover would close the panel), elsewhere as a popover.
struct SessionPicker: View {
    @EnvironmentObject var store: UsageStore
    @AppStorage("chatMenuFolders") private var folders = true
    var inPanel = false
    @ObservedObject private var panel = PanelState.shared
    @State private var popover = false

    var body: some View {
        if folders {
            Button {
                if inPanel { panel.chatListOpen.toggle() } else { popover.toggle() }
            } label: {
                HStack(spacing: 4) {
                    (store.selected.map { SessionPicker.styled("▶\u{FE0E}", SessionPicker.title($0)) } ?? Text("No chat"))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees((inPanel ? panel.chatListOpen : popover) ? 180 : 0))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $popover, arrowEdge: .bottom) {
                ChatBrowser { popover = false }.environmentObject(store).padding(8).frame(width: 340)
            }
        } else {
            Menu {
                ForEach(store.sessions) { s in
                    Button(SessionPicker.label(s, selected: s.id == store.selected?.id)) { store.select(s.id) }
                }
            } label: {
                Text(store.selected.map { SessionPicker.label($0, selected: true) } ?? "No chat").lineLimit(1)
            }
            .menuStyle(.button)
        }
    }

    /// ▶ = the chat shown now, ♨ = another chat whose cache is still warm
    static func label(_ s: Session, selected: Bool) -> String {
        let sym = symbol(s, selected: selected)
        return (sym.isEmpty ? "" : sym + " ") + title(s)
    }
    static func symbol(_ s: Session, selected: Bool) -> String {
        selected ? "▶\u{FE0E}" : s.cacheWarm ? "♨\u{FE0E}" : ""
    }
    static func title(_ s: Session) -> String {
        let t = s.title.count > 30 ? s.title.prefix(29) + "…" : s.title
        return "\(t) · \(s.modified.formatted(.relative(presentation: .named).locale(en)))"
    }
    /// Title with its symbol drawn a size smaller (SwiftUI views; plain menus get `label`)
    static func styled(_ symbol: String, _ text: String) -> Text {
        symbol.isEmpty ? Text(text) : Text(symbol).font(.system(size: 10)) + Text(" " + text)
    }
}

/// The folder list behind "Chat menu: Folders". Folders holding the selected chat or a chat with a warm
/// cache are open by themselves; a click on a folder overrides that until the list is closed.
struct ChatBrowser: View {
    @EnvironmentObject var store: UsageStore
    var picked: () -> Void
    @State private var override: [String: Bool] = [:]
    @State private var hovered: String?
    private let anim = Animation.snappy(duration: 0.14)

    private func isOpen(_ g: FolderGroup) -> Bool {
        override[g.id] ?? (g.sessions.contains { $0.id == store.selected?.id } || g.cacheWarm)
    }

    var body: some View {
        let groups = FolderGroup.make(store.sessions)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { g in
                    let open = isOpen(g)
                    Button {
                        withAnimation(anim) { override[g.id] = !open }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(open ? 90 : 0))
                                .frame(width: 10)
                            let current = g.sessions.contains { $0.id == store.selected?.id }
                            SessionPicker.styled(current ? "▶\u{FE0E}" : g.cacheWarm ? "♨\u{FE0E}" : "", g.name)
                                .fontWeight(.medium).lineLimit(1)
                            Text("\(g.sessions.count)").foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .background(highlight("f" + g.id, selected: false))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? "f" + g.id : (hovered == "f" + g.id ? nil : hovered) }
                    if open {
                        VStack(spacing: 0) { ForEach(g.sessions) { row($0) } }
                            .padding(.leading, 16)
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func highlight(_ key: String, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(
            selected ? Color.accentColor.opacity(0.18)
            : hovered == key ? Color.primary.opacity(0.08) : .clear)
    }

    private func row(_ s: Session) -> some View {
        let sel = s.id == store.selected?.id
        return Button {
            store.select(s.id)
            picked()
        } label: {
            HStack(spacing: 4) {
                SessionPicker.styled(SessionPicker.symbol(s, selected: sel), SessionPicker.title(s)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(highlight(s.id, selected: sel))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? s.id : (hovered == s.id ? nil : hovered) }
    }
}

// MARK: - Small popover: only what matters right now

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @ObservedObject private var panel = PanelState.shared
    private var showSettings: Bool { panel.showSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                if showSettings {
                    Text("Settings").font(.headline)
                    Spacer()
                } else {
                    SessionPicker(inPanel: true)
                }
                // Settings open inside this panel (a popover from the menu bar panel would close it)
                Button { panel.showSettings.toggle() } label: {
                    Image(systemName: showSettings ? "xmark.circle" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help(showSettings ? "Close settings" : "Settings")
                Button { FullDashboardWindow.shared.show(settings: showSettings) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help(showSettings ? "Open settings in the big window" : "Open full dashboard")
            }

            if !showSettings && panel.chatListOpen {
                ChatBrowser { panel.chatListOpen = false }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }

            if showSettings {
                SettingsPanel()
            } else if let s = store.selected {
                let status = CtxStatus(growth: s.growth)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(short(s.lastCtx)).font(.system(size: 30, weight: .semibold)).monospacedDigit()
                        Text("context").foregroundStyle(.secondary)
                        Spacer()
                        Label(status.label, systemImage: "circle.fill")
                            .labelStyle(StatusLabelStyle(color: status.color))
                            .font(.caption)
                    }
                    ProgressView(value: min(Double(s.growth) / Double(Advisor.highGrowth), 1))
                        .tint(status.color)
                    Sparkline(turns: s.turns).frame(height: 34)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        MiniStat(label: "Responses", value: "\(s.turns.count)")
                        MiniStat(label: "Session", value: short(s.weighted))
                        MiniStat(label: "Today", value: short(store.todayWeighted))
                    }
                    Text("Session & Today in weighted tokens (adjusted for what they cost)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                CacheRow(session: s)

                let tips = Advisor.tips(for: s)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tips.prefix(2)) { TipRow(tip: $0, session: s) }
                    if tips.count > 2 {
                        Button("+\(tips.count - 2) more suggestions") { FullDashboardWindow.shared.show() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            } else {
                Text("No sessions found in ~/.claude/projects.").foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Spacer()   // the full dashboard opens with the expand button at the top
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - Cache countdown

/// Live countdown until the prompt cache of this chat expires. After that, the next reply
/// writes the whole context to the cache again (much more expensive than reading it).
struct CacheRow: View {
    let session: Session
    @ObservedObject private var panel = PanelState.shared
    var body: some View {
        // Tick only while the panel is open: a TimelineView keeps running in the hidden panel and
        // re-laid it out every second, which made the dashboard stutter while scrolling.
        if panel.isOpen {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in row(now: ctx.date) }
        } else {
            row(now: Date())
        }
    }

    @ViewBuilder private func row(now: Date) -> some View {
        let left = (session.cacheExpires ?? .distantPast).timeIntervalSince(now)
        let color: Color = left <= 0 ? .secondary : left < 300 ? .orange : .green
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: left > 0 ? "timer" : "snowflake").foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                if left > 0 {
                    Text("Cache warm · \(Self.clock(left)) left").font(.callout.weight(.medium)).monospacedDigit()
                    Text("Reply before then and the context is read cheaply.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    let rewrite = Int(Double(session.lastCtx) * (session.cacheTTL > 300 ? 2 : 1.25))
                    Text("Cache expired").font(.callout.weight(.medium))
                    Text("The next reply writes \(short(session.lastCtx)) context to the cache again (≈ \(short(rewrite)) weighted). In a big chat, a handoff to a new chat is cheaper.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct StatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color).imageScale(.small)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

struct MiniStat: View {
    let label: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
    }
}

struct Sparkline: View {
    let turns: [Turn]
    var body: some View {
        Chart {
            ForEach(Array(turns.enumerated()), id: \.offset) { i, t in
                AreaMark(x: .value("Response", i), y: .value("Context", t.ctx))
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                LineMark(x: .value("Response", i), y: .value("Context", t.ctx))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

struct TipRow: View {
    let tip: Tip
    let session: Session
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(tip.title).font(.callout.weight(.medium))
                Text(tip.text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !tip.actions.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { buttons }
                        VStack(alignment: .leading, spacing: 4) { buttons }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
    @ViewBuilder private var buttons: some View {
        ForEach(Array(tip.actions.enumerated()), id: \.element) { i, a in
            let b = Button { FullDashboardWindow.closeMenuPanel(); a.run(for: session) } label: { Label(a.label, systemImage: a.icon) }
                .controlSize(.small)
                .help(a.help)
            if i == 0 { b.buttonStyle(.borderedProminent) } else { b.buttonStyle(.bordered) }
        }
    }

    private var icon: String {
        switch tip.level {
        case .high: return "exclamationmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .info: return "lightbulb.fill"
        case .good: return "checkmark.circle.fill"
        }
    }
    private var color: Color {
        switch tip.level {
        case .high: return .red
        case .medium: return .orange
        case .info: return .blue
        case .good: return .green
        }
    }
}
