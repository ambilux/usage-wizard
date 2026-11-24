import Foundation
import AppKit
import UserNotifications

/// Reminders with buttons:
/// - When an active chat grows past the reminder point (default +100k, again at 2×, 3× …): "Time for a new chat" with a
///   "Move to new chat" button (step 1, the chat writes its own handoff file).
/// - When that handoff file appears: "Handoff ready" with an "Open new chat" button (step 2).
/// - A few minutes before the prompt cache of a big chat expires: "Cache expires in 5 min" (lead time in Settings).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static var step: Int { Advisor.highGrowth }

    private let center = UNUserNotificationCenter.current()
    private let defaultsKey = "notifiedLevels"
    private var notified: [String: Int]
    private var pendingHandoffs: [String: (folder: String, since: Date)] = [:]   // handoff path -> request
    private var handoffTimer: Timer?

    override init() {
        notified = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "CTX",
                                   actions: [UNNotificationAction(identifier: "MOVE", title: "Move to new chat", options: [.foreground])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "CACHE",
                                   actions: [UNNotificationAction(identifier: "MOVE", title: "Move to new chat", options: [.foreground])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "HANDOFF",
                                   actions: [UNNotificationAction(identifier: "OPEN", title: "Open new chat", options: [.foreground])],
                                   intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Only cache reminders are ever scheduled ahead; drop leftovers from the last run, the first check re-plans them.
        center.removeAllPendingNotificationRequests()
    }

    // MARK: Context reminder

    func check(_ sessions: [Session]) {
        for s in sessions where s.isLive {
            let level = s.growth / Self.step           // 0 below the reminder point, 1 from 1×, 2 from 2× …
            guard level >= 1, level > (notified[s.id] ?? 0) else { continue }
            notified[s.id] = level
            // The handoff prompt was already sent here (e.g. this very reply crossed the point): stay quiet
            if Handoffs.requested(in: s) || Handoffs.written(for: s) != nil { continue }
            sendContextReminder(s)
        }
        let ids = Set(sessions.map(\.id))               // forget sessions whose logs are gone
        notified = notified.filter { ids.contains($0.key) }
        UserDefaults.standard.set(notified, forKey: defaultsKey)
        scheduleCacheReminders(sessions)
    }

    // MARK: Cache reminder

    /// Minutes before the prompt cache expires to remind (0 = off). Default 5, own values 1–55
    /// (a 1-hour cache needs at least a minute between reply and reminder).
    static let cacheLeadKey = "cacheLeadMinutes"
    static let cacheLeadRange = 1...55
    static var cacheLeadMinutes: Int {
        let v = UserDefaults.standard.object(forKey: cacheLeadKey) as? Int ?? 5
        return v <= 0 ? 0 : min(max(v, cacheLeadRange.lowerBound), cacheLeadRange.upperBound)
    }
    static let cacheLeadPresets = [1, 2, 3, 5, 10, 15, 20, 30]

    private var scheduledCache: [String: Date] = [:]   // session id -> planned fire date

    /// Plans one "cache expires soon" notification per chat, at (cache expiry − lead time). Re-planned after
    /// every reply (the expiry moves), dropped when the chat no longer qualifies. Only for chats that are
    /// getting big (a rewrite of a small context is cheap) and that have no handoff yet (already moving on).
    /// Skipped when the lead time would fire right after the reply (e.g. 5-min cache with a 5-min lead).
    func scheduleCacheReminders(_ sessions: [Session]) {
        let lead = TimeInterval(Self.cacheLeadMinutes * 60)
        var wanted: [String: (Date, Session)] = [:]
        if lead > 0 {
            for s in sessions {
                guard let exp = s.cacheExpires, s.cacheTTL > lead + 60,
                      s.growth >= Advisor.warnGrowth, Handoffs.written(for: s) == nil else { continue }
                let fire = exp.addingTimeInterval(-lead)
                if fire > Date().addingTimeInterval(5) { wanted[s.id] = (fire, s) }
            }
        }
        let drop = scheduledCache.keys.filter { wanted[$0] == nil }
        if !drop.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: drop.map { "cache-\($0)" })
            drop.forEach { scheduledCache[$0] = nil }
        }
        for (id, (fire, s)) in wanted where scheduledCache[id] != fire {
            scheduledCache[id] = fire
            let c = UNMutableNotificationContent()
            c.title = "Cache expires in \(Self.cacheLeadMinutes) min"
            c.body = "\"\(s.title)\" (\(short(s.lastCtx)) context): reply before then to keep it cheap, or move to a new chat."
            c.sound = .default
            c.categoryIdentifier = "CACHE"
            c.userInfo = ["cacheSession": s.id]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)
            center.add(UNNotificationRequest(identifier: "cache-\(id)", content: c, trigger: trigger))
        }
    }

    private func sendContextReminder(_ s: Session) {
        let c = UNMutableNotificationContent()
        c.title = "Time for a new chat"
        c.body = "\"\(s.title)\" is at \(short(s.lastCtx)) context. Click to move on."
        c.sound = .default
        c.categoryIdentifier = "CTX"
        c.userInfo = ["session": s.id]
        center.add(UNNotificationRequest(identifier: "ctx-\(s.id)-\(s.growth / Self.step)", content: c, trigger: nil))
    }

    // MARK: Handoff watcher

    func expectHandoff(path: String, folder: String) {
        pendingHandoffs[path] = (folder, Date())
        guard handoffTimer == nil else { return }
        handoffTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.pollHandoffs() }
    }

    private func pollHandoffs() {
        for (path, p) in pendingHandoffs {
            if let mod = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               mod >= p.since.addingTimeInterval(-1) {
                pendingHandoffs[path] = nil
                sendHandoffReady(path: path, folder: p.folder)
            } else if Date().timeIntervalSince(p.since) > 30 * 60 {
                pendingHandoffs[path] = nil              // gave up after 30 min
            }
        }
        if pendingHandoffs.isEmpty { handoffTimer?.invalidate(); handoffTimer = nil }
    }

    private func sendHandoffReady(path: String, folder: String) {
        // Put the "continue from this handoff" prompt on the clipboard right away, so a new chat
        // started any way (click, or by hand) only needs ⌘V + Enter.
        ClaudeAction.copyToClipboard(Prompts.continueFromHandoff(Handoffs.relative(path, in: folder),
                                                                 title: Handoffs.nextTitle(forHandoff: path)))
        let c = UNMutableNotificationContent()
        c.title = "Handoff ready"
        c.body = "Click to open the new chat. Prompt is copied (⌘V)."
        c.sound = .default
        c.categoryIdentifier = "HANDOFF"
        c.userInfo = ["folder": folder, "path": path]
        center.add(UNNotificationRequest(identifier: "handoff-\(path)", content: c, trigger: nil))
    }

    // MARK: Short info

    func info(_ text: String) {
        let c = UNMutableNotificationContent()
        c.title = "Usage Wizard"
        c.body = text
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Delegate

    // Show banners even if the app counts as active
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Clicking the notification or its button does the step
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let tapped = response.actionIdentifier
        let isClick = tapped == UNNotificationDefaultActionIdentifier || tapped == "MOVE" || tapped == "OPEN"
        DispatchQueue.main.async {
            guard isClick else { return }
            if let id = info["cacheSession"] as? String {
                // Button: hand off. Plain click: just bring up the Claude app to reply.
                if tapped == "MOVE", let s = UsageStore.shared.sessions.first(where: { $0.id == id }) {
                    ClaudeAction.moveToNewChat.run(for: s)
                } else {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Claude.app"),
                                                       configuration: .init()) { _, _ in }
                }
            } else if let id = info["session"] as? String,
               let s = UsageStore.shared.sessions.first(where: { $0.id == id }) {
                ClaudeAction.moveToNewChat.run(for: s)
            } else if let folder = info["folder"] as? String, let path = info["path"] as? String {
                let prompt = Prompts.continueFromHandoff(Handoffs.relative(path, in: folder),
                                                         title: Handoffs.nextTitle(forHandoff: path))
                ClaudeAction.copyToClipboard(prompt)
                ClaudeAction.openNewChat(prompt: prompt, folder: folder)
            }
        }
        completionHandler()
    }
}
