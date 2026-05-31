import SwiftUI
import AppKit

// MARK: - Theme

/// "Warm espresso counter" palette. One dominant amber accent expresses the
/// caffeine metaphor; everything else stays neutral so the active state reads
/// instantly. Sits on top of the system menu-bar material (`.window` style).
private enum Theme {
    static let amber       = Color(red: 0.93, green: 0.58, blue: 0.16)
    static let amberBright = Color(red: 0.99, green: 0.71, blue: 0.29)
    static let espresso    = Color(red: 0.82, green: 0.40, blue: 0.11)
    static let good        = Color(red: 0.26, green: 0.78, blue: 0.47)
    static let warn        = Color(red: 0.95, green: 0.42, blue: 0.30)

    /// The warm gradient used for the brand tile and the "Caffeinated" hero.
    static let warmGradient = LinearGradient(
        colors: [amberBright, espresso],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let panelWidth: CGFloat = 296
}

/// The menu shown when the menu bar icon is clicked.
///
/// A custom panel (not a system menu): a status hero, three read-only status
/// tags, and the user controls — Pause / Resume, Refresh, idle grace period,
/// Check for Updates and Quit (spec AC-17, AC-18).
struct MenuContent: View {
    @ObservedObject var state: AppState
    let monitor: ProcessMonitor
    @ObservedObject var updater: UpdateChecker

    /// Transient, in-panel result of the last hook action — shown inline instead
    /// of a modal alert (which would close this panel). Auto-dismisses.
    @State private var feedback: ActionFeedback?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            hero

            if showTelemetry {
                telemetryCard
            }

            if !state.isHelperConnected && HelperConstants.managesPrivilegedHelper {
                helperWarning
            }

            statusTags
            controls
            feedbackBanner
            gracePeriod
            footer
        }
        // Every time the panel opens, re-scan so the status — especially the
        // Helper row after a System Settings toggle — is current immediately
        // rather than up to one poll stale.
        .onAppear { monitor.checkNow() }
        // Auto-dismiss the inline action feedback after a few seconds (UX:
        // transient confirmations shouldn't linger). Keyed on the feedback's id
        // so each new action restarts the timer.
        .task(id: feedback?.id) {
            guard feedback != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.easeOut(duration: 0.2)) { feedback = nil }
        }
        .padding(16)
        .frame(width: Theme.panelWidth)
        // A faint amber wash bleeding down from the header gives the panel
        // warmth without fighting the system vibrancy beneath it.
        .background(
            LinearGradient(colors: [Theme.amber.opacity(0.12), .clear],
                           startPoint: .top, endPoint: .center)
                .allowsHitTesting(false)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            // Brand tile — always warm so the identity stays stable; the hero
            // below is what reflects the live caffeine state.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.warmGradient)
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: Theme.espresso.opacity(0.35), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("Claffeinate")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Text("v\(updater.currentVersion)")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Hero — the single most important truth, told honestly

    private var hero: some View {
        let mode = heroMode
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(mode.isActive ? Color.white.opacity(0.22) : Color.primary.opacity(0.06))
                    .frame(width: 40, height: 40)
                Image(systemName: mode.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(mode.isActive ? .white : .secondary)
                    .symbolEffect(.pulse, isActive: mode.isActive)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(mode.isActive ? .white : .primary)
                Text(mode.subtitle)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(mode.isActive ? Color.white.opacity(0.85) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(mode.isActive
                      ? AnyShapeStyle(Theme.warmGradient)
                      : AnyShapeStyle(Color.primary.opacity(0.05)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(mode.isActive ? 0.18 : 0), lineWidth: 1)
        )
        .shadow(color: mode.isActive ? Theme.espresso.opacity(0.30) : .clear,
                radius: 8, y: 3)
        .animation(.easeInOut(duration: 0.25), value: mode.isActive)
    }

    // MARK: Helper warning banner

    private var helperWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
            Text("Helper not connected — sleep can’t be prevented.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.warn.opacity(0.14))
        )
    }

    // MARK: Inline action feedback

    /// In-panel result of the last hook action (success or failure), styled like
    /// the helper warning for consistency. Animates in/out and auto-dismisses, so
    /// the user sees what happened without the panel closing or a modal popping.
    @ViewBuilder private var feedbackBanner: some View {
        if let feedback {
            HStack(spacing: 8) {
                Image(systemName: feedback.ok
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(feedback.ok ? Theme.good : Theme.warn)
                Text(feedback.message)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((feedback.ok ? Theme.good : Theme.warn).opacity(0.14))
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: Status tags

    private var statusTags: some View {
        VStack(spacing: 0) {
            StatusRow(icon: "sparkles", label: "Claude", tag: claudeTag)
            rowDivider
            StatusRow(icon: "dot.radiowaves.left.and.right",
                      label: "Monitoring",
                      tag: state.isMonitoringPaused
                          ? Tag("Paused", Theme.amber)
                          : Tag("Running", Theme.good))
            rowDivider
            StatusRow(icon: "bolt.horizontal.circle",
                      label: "Helper",
                      tag: !HelperConstants.managesPrivilegedHelper
                          ? Tag("Dev (disabled)", Theme.amber)
                          : (state.isHelperConnected
                              ? Tag("Connected", Theme.good)
                              : Tag("Off", Theme.warn)))
            rowDivider
            StatusRow(icon: "scope", label: "Detection", tag: detectionTag)
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 38).opacity(0.5)
    }

    // MARK: Primary controls

    private var controls: some View {
        VStack(spacing: 8) {
            if state.isMonitoringPaused {
                PanelButton(title: "Resume Monitoring", icon: "play.fill",
                            kind: .primary) { monitor.start() }
            } else {
                PanelButton(title: "Pause Monitoring", icon: "pause.fill",
                            kind: .ghost) { monitor.pause() }
            }

            // "Refresh" re-scans for Claude immediately; named to stay clearly
            // distinct from "Check for Updates…" in the footer.
            PanelButton(title: "Refresh Now", icon: "arrow.clockwise",
                        kind: .ghost) { monitor.checkNow() }
                .disabled(state.isMonitoringPaused)

            // Base the prompt on whether our hooks are actually written to
            // settings.json — not on runtime reporting — so we never ask the user
            // to "set up" hooks that are already installed but haven't fired in a
            // new session yet.
            if !HookInstaller.isInstalled() {
                PanelButton(title: "Set Up Claude Hooks", icon: "scope",
                            kind: .ghost) { installHooks() }
            }

            // Let the user clear our hooks out of ~/.claude/settings.json (this
            // build's, the other build's, and any old residue) when they're present.
            if HookInstaller.isAnyInstalled() {
                PanelButton(title: "Remove Claffeinate Hooks", icon: "trash",
                            kind: .ghost) { uninstallHooks() }
            }
        }
    }

    // MARK: Idle grace period (user-configurable)

    /// How long a Claude work lease keeps the Mac awake after its last hook event
    /// when the closing hook never fires (a Ctrl-C interrupt, a long silent
    /// stretch mid-turn). The minimum is 10 minutes.
    private var gracePeriod: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Idle grace period", systemImage: "hourglass")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(state.gracePeriodMinutes) min")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.espresso)
            }

            HStack(spacing: 5) {
                ForEach(Constants.gracePeriodPresetsMinutes, id: \.self) { minutes in
                    GracePill(minutes: minutes,
                              isSelected: state.gracePeriodMinutes == minutes) {
                        state.gracePeriodMinutes = minutes
                    }
                }
            }
        }
    }

    /// Merge Claffeinate's hooks into the user's Claude settings, then show the
    /// outcome inline. We deliberately do NOT use an `NSAlert` here: a modal
    /// activates the app and steals focus, which closes the `.window`-style
    /// panel — so the user never sees the result in context. Inline feedback
    /// keeps the panel open and shows what happened right where they tapped.
    private func installHooks() { applyHookResult(HookInstaller.install()) }

    /// Remove Claffeinate's hooks from `~/.claude/settings.json` (ours, the other
    /// build's, and any old residue), then show the outcome inline.
    private func uninstallHooks() { applyHookResult(HookInstaller.uninstall()) }

    /// Surface a hook action's result inline in the panel and re-scan so the
    /// Detection/Helper rows update without waiting for the next poll.
    private func applyHookResult(_ result: HookInstaller.Result) {
        withAnimation(.easeOut(duration: 0.2)) {
            feedback = ActionFeedback(message: result.message, ok: result.ok)
        }
        monitor.checkNow()
    }

    // MARK: Footer — updates & quit

    private var footer: some View {
        VStack(spacing: 8) {
            Divider().opacity(0.5)

            // The result is reported in an alert (the panel closes on tap); this
            // line just shows the last outcome the next time the panel opens.
            if let updateStatus = updateStatusText {
                HStack(spacing: 6) {
                    Image(systemName: updateStatus.icon)
                        .foregroundStyle(updateStatus.tint)
                    Text(updateStatus.text)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 8) {
                PanelButton(title: "Check for Updates", icon: "arrow.down.circle",
                            kind: .text) { updater.checkForUpdates() }
                    .disabled(updater.status == .checking)

                PanelButton(title: "Quit", icon: "power",
                            kind: .text, role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }

    // MARK: - Derived view models

    /// The hero's live state, in priority order: prevention wins, then a paused
    /// notice, then "needs attention", otherwise the calm "may sleep" state.
    private var heroMode: HeroMode {
        if state.isSleepAssertionActive {
            // The grace cool-down keeps the Mac awake too, but it's a wind-down,
            // not active work — say so, with how long is left.
            if state.activityReason == .hookGrace {
                return HeroMode(
                    isActive: true,
                    icon: "cup.and.saucer.fill",
                    title: "Caffeinated",
                    subtitle: graceSubtitle)
            }
            return HeroMode(
                isActive: true,
                icon: "cup.and.saucer.fill",
                title: "Caffeinated",
                subtitle: "Claude is working — staying awake")
        }
        if state.isMonitoringPaused {
            return HeroMode(
                isActive: false,
                icon: "pause.circle.fill",
                title: "Paused",
                subtitle: "Not watching for Claude right now.")
        }
        if state.activityState == .needsAttention {
            return HeroMode(
                isActive: false,
                icon: "bell.badge.fill",
                title: "Waiting for you",
                subtitle: "Claude needs your input — your Mac may sleep.")
        }
        return HeroMode(
            isActive: false,
            icon: "moon.zzz.fill",
            title: "Decaf",
            subtitle: decafSubtitle)
    }

    /// Hero subtitle in the resting state — tells the user the Mac may sleep,
    /// and notes when idle Claude sessions exist so "idle" isn't surprising.
    private var decafSubtitle: String {
        guard state.isClaudeRunning else {
            return "Waiting for Claude — your Mac may sleep."
        }
        return state.runningSessionCount > 1
            ? "\(state.runningSessionCount) Claude sessions, all idle — your Mac may sleep."
            : "Claude is idle — your Mac may sleep."
    }

    // MARK: Telemetry — the judgement, made fully legible

    /// Show the telemetry card whenever we're monitoring a running Claude, so the
    /// state and reason are always discoverable. Hidden when paused or when no
    /// Claude exists (nothing to explain).
    private var showTelemetry: Bool {
        !state.isMonitoringPaused && state.isClaudeRunning
    }

    /// A small state card: the state label, an optional "for 12s" turn duration,
    /// and a caption naming what Claude is doing (the *reason*).
    private var telemetryCard: some View {
        let t = telemetry
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.label)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                trailingAccessory(t)
            }
            Text(t.caption)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// The state card's right-aligned status. Active work gets a live
    /// "Caffeinating" pulse (no number — it isn't counting down to anything);
    /// the grace cool-down gets the headline "wears off in 8m" figure, since
    /// that's the moment the question "how much longer?" has a real answer.
    @ViewBuilder
    private func trailingAccessory(_ t: Telemetry) -> some View {
        switch t.trailing {
        case .none:
            EmptyView()
        case .caffeinating:
            HStack(spacing: 5) {
                PulsingDot(color: t.accent)
                Text("Caffeinating")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(t.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous).fill(t.accent.opacity(0.12))
            )
        case .wearsOff(let remaining):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("wears off in")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(remaining)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(t.accent)
            }
        }
    }

    /// View-model for the state card, selected by the resolved state:
    /// BUSY → "Caffeinating" pulse + what Claude is doing; WINDING DOWN →
    /// "wears off in 8m"; NEEDS ATTENTION → waiting note; IDLE → may-sleep note.
    private var telemetry: Telemetry {
        switch state.activityState {
        case .busy where state.activityReason == .hookGrace:
            // Post-turn cool-down: the Mac is still awake, but the turn is over.
            // This is the one moment a countdown is meaningful — surface the time
            // left before the caffeine wears off as the card's headline figure.
            return Telemetry(
                label: "WINDING DOWN",
                trailing: graceRemainingText.map(Telemetry.Trailing.wearsOff) ?? .none,
                accent: Theme.amber,
                caption: joinDot(graceCaption, sessionBreakdown))
        case .busy:
            // Claude is actively working: caffeine is being topped up, so there's
            // no expiry to show. A climbing "for Ns" only invited the "but my
            // grace is 30m" confusion — show a live "Caffeinating" pulse instead.
            return Telemetry(
                label: "ACTIVE",
                trailing: .caffeinating,
                accent: Theme.good,
                caption: joinDot(busyPhrase, sessionBreakdown))
        case .needsAttention:
            return Telemetry(
                label: "NEEDS ATTENTION",
                trailing: .none,
                accent: Theme.amber,
                caption: "Claude is waiting for you · your Mac may sleep")
        case .idle:
            return Telemetry(
                label: "IDLE",
                trailing: .none,
                accent: .secondary,
                caption: joinDot("No active turn · may sleep now", sessionBreakdown))
        }
    }

    /// Plain-language description of *what* Claude is doing, for the busy caption.
    /// The technical source (hooks vs transcript) is carried by the `Detection` row.
    private var busyPhrase: String {
        switch state.activityReason {
        case .hookTurn:      return "Answering a prompt"
        case .hookTool:      return "Running a tool"
        case .hookSubagent:  return "Running a subagent"
        case .hookGrace:     return "Winding down after a turn"
        case .transcript:    return "Streaming a response"
        case .hookAttention, .none: return "Working"
        }
    }

    /// Hero subtitle during the post-turn grace cool-down: the Mac is awake but
    /// the turn has ended, with roughly how long the grace period has left.
    private var graceSubtitle: String {
        guard let remaining = graceRemainingText else {
            return "Claude's turn ended — winding down."
        }
        return "Claude's turn ended — caffeine wears off in \(remaining)."
    }

    /// Telemetry caption for the grace cool-down (no leading phrase duplication
    /// with the hero subtitle — this names the period and its remaining time).
    private var graceCaption: String {
        return "Idle grace period · Mac may sleep after"
    }

    /// Coarse "8m" / "45s" until the grace lease expires. nil when unknown or
    /// already lapsed (the next scan will move us out of the grace state).
    private var graceRemainingText: String? {
        guard let until = state.graceUntil else { return nil }
        let seconds = Int(until.timeIntervalSinceNow)
        guard seconds > 0 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }

    /// Optional "4 sessions · auto-mode" footnote, shown only when noteworthy.
    private var sessionBreakdown: String? {
        var parts: [String] = []
        if state.runningSessionCount > 1 { parts.append("\(state.runningSessionCount) sessions") }
        if state.hasAutoModeSession { parts.append("auto-mode") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func joinDot(_ parts: String?...) -> String {
        parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// The Claude status as a tinted tag: Working / Waiting / Idle / Not running.
    private var claudeTag: Tag {
        guard state.isClaudeRunning else { return Tag("Not running", .secondary) }
        switch state.activityState {
        case .busy where state.activityReason == .hookGrace:
            return Tag("Winding down", Theme.good)
        case .busy:           return Tag("Working", Theme.good)
        case .needsAttention: return Tag("Waiting", Theme.amber)
        case .idle:           return Tag("Idle", Theme.amber)
        }
    }

    /// Detection-source tag: precise hooks vs the CPU/transcript fallback. Nudges
    /// the user toward installing hooks when they're not yet active.
    private var detectionTag: Tag {
        state.hooksActive ? Tag("Hooks", Theme.good) : Tag("Transcript", Theme.amber)
    }

    /// One-line summary of the most recent update check, or nil before the user
    /// has run one (so the panel stays clean until asked).
    private var updateStatusText: (text: String, icon: String, tint: Color)? {
        switch updater.status {
        case .idle:
            return nil
        case .checking:
            return ("Checking for updates…", "arrow.triangle.2.circlepath", .secondary)
        case .upToDate(let current):
            return ("Up to date (v\(current))", "checkmark.circle.fill", Theme.good)
        case .updateAvailable(let info):
            return ("Update available: v\(info.latest)", "arrow.up.circle.fill", Theme.amber)
        case .failed(let message):
            return ("Update check failed: \(message)", "xmark.circle.fill", Theme.warn)
        }
    }

}

// MARK: - Hero view model

private struct HeroMode {
    let isActive: Bool
    let icon: String
    let title: String
    let subtitle: String
}

// MARK: - Telemetry

/// View-model for the state card shown at a time.
private struct Telemetry {
    let label: String           // state: "ACTIVE" / "NEEDS ATTENTION" / "IDLE"
    /// The right-aligned accessory: what the user most wants to know about the
    /// caffeine right now — that it's actively topping up, or how long until it
    /// wears off and the Mac may sleep.
    let trailing: Trailing
    let accent: Color           // tint for the trailing figure
    let caption: String

    /// The state card's trailing status, framed around the one question users
    /// actually ask: "how much longer will my Mac stay awake?"
    enum Trailing {
        case none
        /// Active work: caffeine is being topped up, so there's no expiry to
        /// count down — we show a live "Caffeinating" pulse, never a number.
        case caffeinating
        /// Post-turn grace: the figure the user wants — time left before the
        /// caffeine wears off and the Mac may sleep, e.g. "8m".
        case wearsOff(String)
    }
}

// MARK: - Pulsing dot

/// A small dot that gently breathes — the visual cue that caffeine is actively
/// being topped up. A halo ring expands and fades behind a steady core, so the
/// "Caffeinating" pill reads as live without ever jittering a number.
private struct PulsingDot: View {
    let color: Color
    @State private var animating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Circle()
                .stroke(color, lineWidth: 1.5)
                .frame(width: 6, height: 6)
                .scaleEffect(animating ? 2.4 : 1)
                .opacity(animating ? 0 : 0.6)
        }
        .onAppear { animating = true }
        .animation(
            .easeOut(duration: 1.4).repeatForever(autoreverses: false),
            value: animating
        )
    }
}

// MARK: - Status tag

/// A pill of state: a colored mini-dot plus a label, tinted to match.
private struct Tag {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }
}

/// One read-only status line: leading symbol, label, trailing tinted tag.
private struct StatusRow: View {
    let icon: String
    let label: String
    let tag: Tag

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.system(.subheadline, design: .rounded))
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(tag.color).frame(width: 6, height: 6)
                Text(tag.text)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(tag.color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tag.color.opacity(0.14)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

// MARK: - Inline action feedback model

/// A transient success/failure message shown inline in the panel. `id` makes
/// each occurrence distinct so the auto-dismiss timer restarts per action.
private struct ActionFeedback: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let ok: Bool
}

// MARK: - Grace-period pill

private struct GracePill: View {
    let minutes: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(minutes)")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected
                              ? AnyShapeStyle(Theme.warmGradient)
                              : AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Panel button

/// A hover- and press-aware button in three weights: a filled `primary`, a
/// subtle `ghost`, and a quiet `text` button for the footer.
private struct PanelButton: View {
    enum Kind { case primary, ghost, text }

    let title: String
    let icon: String
    let kind: Kind
    var role: ButtonRole? = nil
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(.subheadline, design: .rounded).weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, kind == .text ? 6 : 9)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 && isEnabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var isDestructive: Bool { role == .destructive }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .ghost:   return .primary
        case .text:    return isDestructive ? Theme.warn : .secondary
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary:
            return AnyShapeStyle(Theme.warmGradient)
        case .ghost:
            return AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.05))
        case .text:
            let tint = isDestructive ? Theme.warn : Color.primary
            return AnyShapeStyle(tint.opacity(hovering ? 0.10 : 0))
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary: return .white.opacity(0.18)
        case .ghost:   return .primary.opacity(0.08)
        case .text:    return .clear
        }
    }
}

/// The menu bar icon. Filled cup while sleep is being prevented, outline cup
/// otherwise, so the active state is visible at a glance.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: state.isSleepAssertionActive
                  ? "cup.and.saucer.fill"
                  : "cup.and.saucer")

            #if DEBUG
            // Mark dev builds so a Debug build is unmistakable next to the
            // installed Release app in the same menu bar. A short "DEV" word
            // (not just a colour) stays legible and accessible; the bordered pill
            // is drawn in the menu-bar foreground colour, so it renders monochrome
            // and inverts correctly on light/dark bars and when the item is
            // highlighted — no hardcoded colours that would break on selection.
            Text("DEV")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 3)
                .padding(.vertical, 0.5)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(lineWidth: 1)
                )
            #endif
        }
    }
}
