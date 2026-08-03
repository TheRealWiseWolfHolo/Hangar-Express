import SwiftUI

struct ItemTranslationMethodChooserView: View {
    let prompt: AppModel.ItemTranslationMethodPrompt
    let onSelect: (HangarItemTranslationMissMode) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if prompt.reason == .appUpdate {
                        Text("New in 1.0.9")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.blue.opacity(0.12), in: Capsule())
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Choose a Translation Method")
                            .font(.title2.weight(.bold))

                        Text("Choose how Hangar Express handles Hangar item text that is missing from the approved dictionary when you use a translated item language.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    translationMethodCard(
                        mode: .cloudReview,
                        title: "Cloud Translation",
                        icon: "icloud.and.arrow.up",
                        description: "Uploads only text that needs translation, with no personally identifiable information. Missing text may remain in English until it is processed, reviewed, and published.",
                        actionTitle: "Use Cloud"
                    )

                    translationMethodCard(
                        mode: .onDevice,
                        title: "Local Translation",
                        icon: "iphone.gen3",
                        description: "Uses Apple’s on-device translation model for missing text. The text stays on this device, and the translation model may need to download first.",
                        actionTitle: "Use Local"
                    )

                    Label(
                        "Both methods use the approved dictionary first. You can switch at any time in Settings under Item Translation.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .padding(20)
            }
            .navigationTitle("Item Translation")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func translationMethodCard(
        mode: HangarItemTranslationMissMode,
        title: LocalizedStringKey,
        icon: String,
        description: LocalizedStringKey,
        actionTitle: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(mode == .cloudReview ? Color.blue : Color.secondary)
                    .frame(width: 42, height: 42)
                    .background(
                        (mode == .cloudReview ? Color.blue : Color.secondary).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                Text(title)
                    .font(.headline)

                Spacer()

                if prompt.currentMode == mode {
                    Text("Current")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
            }

            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onSelect(mode)
            } label: {
                Text(actionTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(mode == .cloudReview ? Color.blue : Color(uiColor: .systemGray3))
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.primary.opacity(0.09), lineWidth: 1)
        }
    }
}
