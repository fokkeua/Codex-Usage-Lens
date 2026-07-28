import AppKit
import SwiftUI

enum CodexVisualStyle {
    static let accent = Color(
        red: 0.16,
        green: 0.63,
        blue: 0.68
    )
    static let windowPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let panelPadding: CGFloat = 16
    static let panelCornerRadius: CGFloat = 12
    static let controlCornerRadius: CGFloat = 7

    static let windowTitleFont = Font.system(
        size: 24,
        weight: .semibold
    )
    static let sectionTitleFont = Font.system(
        size: 15,
        weight: .semibold
    )
    static let rowTitleFont = Font.system(
        size: 12,
        weight: .medium
    )
    static let captionFont = Font.system(size: 11.5)
    static let metricFont = Font.system(
        size: 22,
        weight: .semibold
    )
}

extension Color {
    static let codexAccent = CodexVisualStyle.accent
}

struct CodexSectionHeading: View {
    let title: String
    let subtitle: String?
    let systemImage: String?

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.codexAccent)
                    .frame(width: 16, height: 18)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(title))
                    .font(CodexVisualStyle.sectionTitleFont)

                if let subtitle {
                    Text(L10n.string(subtitle))
                        .font(CodexVisualStyle.captionFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension View {
    func codexPanel(
        padding: CGFloat = CodexVisualStyle.panelPadding
    ) -> some View {
        self
            .padding(padding)
            .background(
                Color.primary.opacity(0.035),
                in: RoundedRectangle(
                    cornerRadius: CodexVisualStyle.panelCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: CodexVisualStyle.panelCornerRadius,
                    style: .continuous
                )
                .stroke(Color.primary.opacity(0.08))
            }
    }

    func codexWindowSurface() -> some View {
        self
            .background(.regularMaterial)
            .tint(.codexAccent)
    }
}
