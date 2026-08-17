import SwiftUI
import UIKit

nonisolated enum HangarTranslationPhraseParser {
    static func colonSeparatedPhrases(in source: String) -> [String]? {
        let components = source.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2 else {
            return nil
        }

        let phrases = components.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard phrases.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        return phrases
    }
}

struct HangarTranslatedText: View {
    let source: String
    let itemTranslator: HangarItemTranslator
    var allowsOnDeviceTranslation = true
    var allowsOnDemandTranslation = false
    var translatesColonSeparatedPhrasesIndividually = false

    @AppStorage(HangarItemTranslationMissMode.storageKey)
    private var itemTranslationMissModeRawValue = HangarItemTranslationMissMode.onDevice.rawValue
    @State private var translationService = OnDeviceHangarItemTranslationService.shared
    @State private var onDemandTranslation: String?
    @State private var onDemandTranslationIdentity: String?

    private var allowsEffectiveOnDeviceTranslation: Bool {
        allowsOnDeviceTranslation
            && HangarItemTranslationMissMode.resolved(
                from: itemTranslationMissModeRawValue
            ) == .onDevice
    }

    private var translationIdentity: String {
        [
            translationSources.joined(separator: "\u{1F}"),
            itemTranslator.language.rawValue,
            itemTranslator.dictionary?.locale ?? "no-locale",
            String(itemTranslator.dictionary?.version ?? 0)
        ].joined(separator: "|")
    }

    private var translationSources: [String] {
        guard translatesColonSeparatedPhrasesIndividually,
              let phrases = HangarTranslationPhraseParser.colonSeparatedPhrases(in: source) else {
            return [source]
        }

        return phrases
    }

    private var translationSeparator: String {
        translationSources.count > 1 ? ": " : ""
    }

    private var displayText: String {
        guard allowsEffectiveOnDeviceTranslation else {
            return translationSources
                .map(itemTranslator.translated(_:))
                .joined(separator: translationSeparator)
        }

        if allowsOnDemandTranslation,
           onDemandTranslationIdentity == translationIdentity,
           let onDemandTranslation {
            return onDemandTranslation
        }

        return translationSources
            .map {
                translationService.displayText(
                    for: $0,
                    using: itemTranslator
                )
            }
            .joined(separator: translationSeparator)
    }

    var body: some View {
        // Reading the generation keeps this view current without replacing its identity.
        // The stable reveal view can then animate English into the translated result.
        let _ = translationService.cacheGeneration

        HangarTranslationRevealText(
            text: displayText,
            animatesChanges: itemTranslator.language != .original
        )
            .id(revealIdentity)
            .task(id: onDemandTaskID) {
                await loadOnDemandTranslationIfNeeded()
            }
    }

    private var revealIdentity: String {
        [
            translationSources.joined(separator: "\u{1F}"),
            itemTranslator.language.rawValue
        ].joined(separator: "|")
    }

    private var onDemandTaskID: String {
        allowsEffectiveOnDeviceTranslation && allowsOnDemandTranslation
            ? translationIdentity
            : "disabled"
    }

    private func loadOnDemandTranslationIfNeeded() async {
        guard allowsEffectiveOnDeviceTranslation, allowsOnDemandTranslation else {
            onDemandTranslation = nil
            onDemandTranslationIdentity = nil
            return
        }

        let currentIdentity = translationIdentity
        onDemandTranslation = nil
        onDemandTranslationIdentity = nil

        var translatedPhrases: [String] = []
        for translationSource in translationSources {
            translatedPhrases.append(
                await translationService.onDemandDisplayText(
                    for: translationSource,
                    using: itemTranslator
                )
            )
        }
        let translatedText = translatedPhrases.joined(separator: translationSeparator)

        guard !Task.isCancelled, currentIdentity == translationIdentity else {
            return
        }

        onDemandTranslation = translatedText
        onDemandTranslationIdentity = currentIdentity
    }
}

private struct HangarTranslationRevealText: View {
    let text: String
    let animatesChanges: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedText: String
    @State private var previousText: String?
    @State private var revealProgress: CGFloat = 1
    @State private var cleanupTask: Task<Void, Never>?

    init(text: String, animatesChanges: Bool) {
        self.text = text
        self.animatesChanges = animatesChanges
        _displayedText = State(initialValue: text)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let previousText {
                Text(previousText)
                    .mask {
                        HangarTranslationWipeMask(
                            progress: revealProgress,
                            revealsLeadingEdge: false
                        )
                    }
                    .accessibilityHidden(true)
            }

            Text(displayedText)
                .mask {
                    HangarTranslationWipeMask(
                        progress: previousText == nil ? 1 : revealProgress,
                        revealsLeadingEdge: true
                    )
                }
                .accessibilityHidden(true)

            if previousText != nil {
                Text(displayedText)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.16, green: 0.65, blue: 1.00),
                                Color(red: 0.48, green: 0.34, blue: 1.00),
                                Color(red: 0.94, green: 0.34, blue: 0.76),
                                Color(red: 1.00, green: 0.58, blue: 0.24)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .mask {
                        HangarTranslationGlowMask(progress: revealProgress)
                    }
                    .shadow(color: Color.blue.opacity(0.42), radius: 3)
                    .shadow(color: Color.purple.opacity(0.32), radius: 5)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(displayedText))
        .onChange(of: text) { _, newText in
            transition(to: newText)
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            guard shouldReduceMotion else { return }
            finishTransition()
        }
        .onDisappear {
            cleanupTask?.cancel()
        }
    }

    private func transition(to newText: String) {
        guard newText != displayedText else { return }

        cleanupTask?.cancel()
        guard animatesChanges, !reduceMotion else {
            displayedText = newText
            previousText = nil
            revealProgress = 1
            return
        }

        previousText = displayedText
        displayedText = newText
        revealProgress = 0

        withAnimation(.easeInOut(duration: 0.72)) {
            revealProgress = 1
        }

        cleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(780))
            guard !Task.isCancelled else { return }
            finishTransition()
        }
    }

    private func finishTransition() {
        cleanupTask?.cancel()
        cleanupTask = nil
        previousText = nil
        revealProgress = 1
    }
}

private struct HangarTranslationWipeMask: View {
    let progress: CGFloat
    let revealsLeadingEdge: Bool

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = min(max(progress, 0), 1)
            let revealedWidth = proxy.size.width * clampedProgress

            Rectangle()
                .frame(
                    width: revealsLeadingEdge
                        ? revealedWidth
                        : max(proxy.size.width - revealedWidth, 0)
                )
                .offset(x: revealsLeadingEdge ? 0 : revealedWidth)
        }
    }
}

private struct HangarTranslationGlowMask: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = min(max(progress, 0), 1)
            let bandWidth = min(max(proxy.size.width * 0.16, 18), 42)

            LinearGradient(
                colors: [.clear, .white, .white, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: bandWidth)
            .offset(x: proxy.size.width * clampedProgress - bandWidth * 0.55)
        }
    }
}

struct IMEAwareSearchRow: View {
    @Binding private var text: String
    @Binding private var isActive: Bool

    private let prompt: String
    private let onCommittedTextChange: () -> Void

    init(
        text: Binding<String>,
        isActive: Binding<Bool> = .constant(false),
        prompt: String,
        onCommittedTextChange: @escaping () -> Void = {}
    ) {
        _text = text
        _isActive = isActive
        self.prompt = prompt
        self.onCommittedTextChange = onCommittedTextChange
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)

            IMEAwareSearchTextField(
                text: $text,
                placeholder: prompt,
                onEditingChanged: { isEditing in
                    isActive = isEditing || !text.isEmpty
                },
                onCommittedTextChange: onCommittedTextChange
            )
            .frame(minHeight: 26)

            if !text.isEmpty {
                Button {
                    text = ""
                    isActive = false
                    onCommittedTextChange()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear Search"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

private struct IMEAwareSearchTextField: UIViewRepresentable {
    @Binding var text: String

    let placeholder: String
    let onEditingChanged: (Bool) -> Void
    let onCommittedTextChange: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.borderStyle = .none
        textField.clearButtonMode = .never
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.textContentType = .none
        textField.font = UIFont.preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        uiView.placeholder = placeholder

        guard uiView.text != text,
              !context.coordinator.hasMarkedText(in: uiView) else {
            return
        }

        uiView.text = text
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: IMEAwareSearchTextField

        init(parent: IMEAwareSearchTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            guard !hasMarkedText(in: textField) else {
                return
            }

            commit(textField.text ?? "")
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onEditingChanged(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            commit(textField.text ?? "")
            parent.onEditingChanged(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        func hasMarkedText(in textField: UITextField) -> Bool {
            guard let markedRange = textField.markedTextRange else {
                return false
            }

            return textField.offset(from: markedRange.start, to: markedRange.end) > 0
        }

        private func commit(_ value: String) {
            guard parent.text != value else {
                return
            }

            parent.text = value
            parent.onCommittedTextChange()
        }
    }
}
