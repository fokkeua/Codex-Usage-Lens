import AppKit
import SwiftUI

struct AboutAppMetadata: Equatable {
    let version: String
    let build: String

    static func current(bundle: Bundle = .main) -> AboutAppMetadata {
        AboutAppMetadata(
            version: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "1.3",
            build: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "7"
        )
    }
}

enum AboutDestination: String, CaseIterable, Identifiable {
    case github
    case documentation
    case issues
    case license

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .github:
            "about.github.title"
        case .documentation:
            "about.documentation.title"
        case .issues:
            "about.issues.title"
        case .license:
            "about.license.title"
        }
    }

    var subtitleKey: String {
        switch self {
        case .github:
            "about.github.subtitle"
        case .documentation:
            "about.documentation.subtitle"
        case .issues:
            "about.issues.subtitle"
        case .license:
            "about.license.subtitle"
        }
    }

    var systemImage: String {
        switch self {
        case .github:
            "chevron.left.forwardslash.chevron.right"
        case .documentation:
            "book.pages"
        case .issues:
            "ladybug"
        case .license:
            "doc.text"
        }
    }

    var url: URL {
        switch self {
        case .github:
            URL(
                string: "https://github.com/fokkeua/Codex-Usage-Lens"
            )!
        case .documentation:
            URL(
                string:
                    "https://github.com/fokkeua/Codex-Usage-Lens#readme"
            )!
        case .issues:
            URL(
                string:
                    "https://github.com/fokkeua/Codex-Usage-Lens/issues/new/choose"
            )!
        case .license:
            URL(
                string:
                    "https://github.com/fokkeua/Codex-Usage-Lens/blob/main/LICENSE"
            )!
        }
    }
}

struct AboutView: View {
    private let metadata: AboutAppMetadata

    init(metadata: AboutAppMetadata = .current()) {
        self.metadata = metadata
    }

    var body: some View {
        VStack(spacing: CodexVisualStyle.sectionSpacing) {
            appHeader
            descriptionPanel
            linksPanel
            independentProjectNote
        }
        .padding(CodexVisualStyle.windowPadding)
        .frame(width: 520)
        .codexWindowSurface()
    }

    private var appHeader: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .accessibilityHidden(true)

            Text("Codex Usage Lens")
                .font(CodexVisualStyle.windowTitleFont)

            Text(
                L10n.format(
                    "about.versionBuild",
                    metadata.version,
                    metadata.build
                )
            )
            .font(CodexVisualStyle.captionFont.weight(.medium))
            .foregroundStyle(.secondary)

            Text(L10n.string("about.tagline"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var descriptionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            CodexSectionHeading(
                "about.overview.title",
                systemImage: "chart.bar.xaxis"
            )

            Text(L10n.string("about.description"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                L10n.string("about.privacy"),
                systemImage: "lock.shield"
            )
            .font(CodexVisualStyle.rowTitleFont)
            .foregroundStyle(Color.codexAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .codexPanel(padding: 14)
    }

    private var linksPanel: some View {
        VStack(spacing: 0) {
            ForEach(
                Array(AboutDestination.allCases.enumerated()),
                id: \.element.id
            ) { index, destination in
                Link(destination: destination.url) {
                    HStack(spacing: 11) {
                        Image(systemName: destination.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.codexAccent)
                            .frame(width: 18)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.string(destination.titleKey))
                                .font(CodexVisualStyle.rowTitleFont)
                                .foregroundStyle(.primary)
                            Text(L10n.string(destination.subtitleKey))
                                .font(CodexVisualStyle.captionFont)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < AboutDestination.allCases.count - 1 {
                    Divider()
                        .padding(.leading, 43)
                }
            }
        }
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

    private var independentProjectNote: some View {
        Text(L10n.string("about.independent"))
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}
