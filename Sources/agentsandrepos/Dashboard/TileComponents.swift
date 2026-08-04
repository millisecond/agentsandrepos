import AgentsAndReposCore
import SwiftUI

extension Color {
    init(severity: TileSeverity) {
        switch severity {
        case .muted: self = .secondary
        case .ok: self = .green
        case .info: self = .blue
        case .attention: self = .orange
        case .urgent: self = .red
        }
    }
}

/// Square card container: rounded rect with a severity-tinted border and a
/// faint severity wash so state reads at a glance.
struct Tile<Content: View>: View {
    let severity: TileSeverity
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 112)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(severity: severity).opacity(severity == .muted ? 0.04 : 0.09))
            )
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Color(severity: severity).opacity(severity == .muted ? 0.25 : 0.55),
                        lineWidth: 1.5)
            )
    }
}

/// Small pill like "● 3 modified" in a semantic color. `compact` drops the
/// word (the fallback when a full badge row wouldn't fit the tile).
struct CountBadge: View {
    let symbol: String
    let count: Int
    let label: String
    let color: Color
    var compact = false

    var body: some View {
        Text(compact ? "\(symbol)\(count)" : "\(symbol) \(count) \(label)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .help("\(count) \(label)")
    }
}

/// Corner indicator on repo tiles: CI dot (worst status) + PR count.
struct PRIndicator: View {
    let ci: PullRequest.CIStatus
    let prCount: Int

    var body: some View {
        if prCount > 0 {
            HStack(spacing: 3) {
                if ci != .none {
                    Circle().fill(ciColor).frame(width: 7, height: 7)
                }
                Text("\(prCount)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ciColor: Color {
        switch ci {
        case .pass: return .green
        case .fail: return .red
        case .pending: return .yellow
        case .none: return .clear
        }
    }
}

/// Row of tiny state dots — circles for agents, squares for worktrees.
struct MiniDotRow: View {
    enum DotShape { case circle, square }

    let dots: [TileSeverity]
    var shape: DotShape = .circle
    private let maxDots = 5

    var body: some View {
        if !dots.isEmpty {
            HStack(spacing: 3) {
                ForEach(Array(dots.prefix(maxDots).enumerated()), id: \.offset) { _, sev in
                    dot(Color(severity: sev))
                }
                if dots.count > maxDots {
                    Text("+\(dots.count - maxDots)")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func dot(_ color: Color) -> some View {
        switch shape {
        case .circle:
            Circle().fill(color).frame(width: 5, height: 5)
        case .square:
            RoundedRectangle(cornerRadius: 1.2).fill(color).frame(width: 5, height: 5)
        }
    }
}

/// Whether the dashboard is on screen. Continuous animations must not run
/// while false: the popover's window outlives close, and an offscreen
/// repeat-forever animation keeps the display cycle (and CPU) busy forever.
private struct DashboardLiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var dashboardLive: Bool {
        get { self[DashboardLiveKey.self] }
        set { self[DashboardLiveKey.self] = newValue }
    }
}

/// Continuously rotating gear for busy agents — "working", not a settings
/// button and not a refresh arrow. Renders static while the dashboard is
/// hidden; the animated leaf is only in the hierarchy while live, so closing
/// the popover tears the animation down and reopening starts it fresh.
struct SpinningGear: View {
    let color: Color
    var size: CGFloat = 17
    @Environment(\.dashboardLive) private var live
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if live, !reduceMotion {
            AnimatedGear(color: color, size: size)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
        }
    }
}

/// State lives in this leaf so snapshot re-renders don't restart the
/// rotation phase.
private struct AnimatedGear: View {
    let color: Color
    let size: CGFloat
    @State private var spinning = false

    var body: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

/// Small eye-slash button revealed in a tile's corner on hover — one click
/// moves the tile to the Ignored list.
struct TileIgnoreButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye.slash")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(4)
                .background(Circle().fill(.thickMaterial))
        }
        .buttonStyle(.plain)
        .padding(4)
        .help(help)
    }
}

/// Compact row in the Ignored section: dimmed name + location, with a
/// one-click restore button.
struct IgnoredRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: restore) {
                Image(systemName: "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show again")
        }
        .padding(.vertical, 1)
    }
}

/// One LLM-summary line: previous text (or the truncated raw facts, before the
/// first summary lands) stays visible with a mini spinner while a replacement
/// generates.
struct SummaryLine: View {
    let display: SummaryDisplay
    var font: Font = .caption2
    var lineLimit = 2
    /// Optional leading SF Symbol (e.g. person/sparkle to tell the agent
    /// tile's user and agent lines apart).
    var icon: String?
    @Environment(\.dashboardLive) private var live

    var body: some View {
        if !display.isEmpty {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Text(display.text ?? "")
                    .font(font)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                // The indeterminate spinner is a continuous animation — hide
                // it while the dashboard is offscreen (see DashboardLiveKey).
                if display.isRefreshing, live {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
    }
}

/// Section header inside the dashboard.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }
}

/// Muted info row for empty/error states ("No agents running", gh hints).
struct InfoRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }
}
