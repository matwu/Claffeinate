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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            hero

            if !state.isHelperConnected {
                helperWarning
            }

            statusTags
            controls
            gracePeriod
            footer
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
                      tag: state.isHelperConnected
                          ? Tag("Connected", Theme.good)
                          : Tag("Off", Theme.warn))
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
        }
    }

    // MARK: Idle grace period (user-configurable, spec AC-4a)

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
    /// notice, otherwise the calm "may sleep" resting state.
    private var heroMode: HeroMode {
        if state.isSleepAssertionActive {
            return HeroMode(
                isActive: true,
                icon: "cup.and.saucer.fill",
                title: "Caffeinated",
                subtitle: lastActivityText.map { "Keeping your Mac awake · \($0)" }
                    ?? "Keeping your Mac awake")
        }
        if state.isMonitoringPaused {
            return HeroMode(
                isActive: false,
                icon: "pause.circle.fill",
                title: "Paused",
                subtitle: "Not watching for Claude right now.")
        }
        return HeroMode(
            isActive: false,
            icon: "moon.zzz.fill",
            title: "Decaf",
            subtitle: state.isClaudeRunning
                ? "Claude is idle — your Mac may sleep."
                : "Waiting for Claude — your Mac may sleep.")
    }

    /// The Claude status as a tinted tag (spec AC-17): Active / Idle / Off.
    private var claudeTag: Tag {
        guard state.isClaudeRunning else { return Tag("Not running", .secondary) }
        return state.isClaudeActive
            ? Tag("Active", Theme.good)
            : Tag("Idle", Theme.amber)
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
        case .updateAvailable(let latest, _):
            return ("Update available: v\(latest)", "arrow.up.circle.fill", Theme.amber)
        case .failed(let message):
            return ("Update check failed: \(message)", "xmark.circle.fill", Theme.warn)
        }
    }

    /// "N min ago" / "just now" since Claude was last seen processing. Re-derived
    /// on every render (each monitoring tick updates `state`). nil when there's
    /// no recorded activity, so the hero subtitle simply omits it.
    private var lastActivityText: String? {
        guard let last = state.lastActivityAt else { return nil }
        let minutes = Int(Date().timeIntervalSince(last) / 60)
        return minutes < 1 ? "active just now" : "active \(minutes) min ago"
    }
}

// MARK: - Hero view model

private struct HeroMode {
    let isActive: Bool
    let icon: String
    let title: String
    let subtitle: String
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
        Image(systemName: state.isSleepAssertionActive
              ? "cup.and.saucer.fill"
              : "cup.and.saucer")
    }
}
