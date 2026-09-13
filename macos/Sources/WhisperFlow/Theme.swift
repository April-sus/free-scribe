import SwiftUI

/// Our own look, built from primitives that exist on every SwiftUI platform.
/// Nothing here uses macOS-only form chrome, so the whole UI ports as-is.
enum Theme {
    /// Deliberately not a system accent: the app should look like itself.
    static let accent = Color(red: 0.30, green: 0.78, blue: 0.69)
    static let warning = Color(red: 0.96, green: 0.62, blue: 0.26)

    static let corner: CGFloat = 14
    static let cardPadding: CGFloat = 16

    static var separator: Color { .primary.opacity(0.08) }
    static var cardBorder: Color { .primary.opacity(0.07) }
}

/// A titled group of rows. Replaces `Section` inside a grouped `Form`.
struct Card<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            VStack(spacing: 0) { content }
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .strokeBorder(Theme.cardBorder)
                )

            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// One labelled line inside a `Card`: title (and optional explanation) on the left,
/// whatever control you pass on the right.
struct Row<Control: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Takes the slack so the control keeps its natural size, and wraps
            // rather than pushing the control off the edge.
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)
            control
                .layoutPriority(1)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 10)
    }
}

/// Hairline between rows. Skipped after the last one by the caller.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.leading, Theme.cardPadding)
    }
}

/// A short coloured strip for states the user has to act on.
struct Banner: View {
    var icon: String
    var message: String
    var tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.25)))
    }
}
