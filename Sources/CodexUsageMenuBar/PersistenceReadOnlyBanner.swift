import SwiftUI

struct PersistenceReadOnlyBanner: View {
    let message: String
    var compact = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Только чтение")
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                Text(L10n.presentation(message))
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 3 : nil)
            }
        } icon: {
            Image(systemName: "lock.fill")
                .foregroundStyle(Color.usageOrange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 8 : 10)
        .background(
            Color.usageOrange.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.usageOrange.opacity(0.25))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Режим только для чтения")
        .accessibilityValue(L10n.presentation(message))
    }
}
