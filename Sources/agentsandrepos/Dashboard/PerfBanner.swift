import SwiftUI

/// Red banner pinned atop the dashboard while the app itself is burning CPU —
/// shown to everyone, not just dev builds: a background app misbehaving on the
/// user's machine is exactly what they need to know about.
struct PerfBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.caption.weight(.semibold))
                Text("Restarting the app should help — please report a bug if it comes back.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.red.opacity(0.55), lineWidth: 1.5)
        )
    }
}
