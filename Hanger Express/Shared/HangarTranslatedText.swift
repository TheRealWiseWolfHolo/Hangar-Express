import SwiftUI
import UIKit

struct HangarTranslatedText: View {
    let source: String
    let itemTranslator: HangarItemTranslator
    var allowsOnDeviceTranslation = true
    var allowsOnDemandTranslation = false

    @State private var translationService = OnDeviceHangarItemTranslationService.shared
    @State private var onDemandTranslation: String?
    @State private var onDemandTranslationIdentity: String?

    private var translationIdentity: String {
        [
            source,
            itemTranslator.language.rawValue,
            itemTranslator.dictionary?.locale ?? "no-locale",
            String(itemTranslator.dictionary?.version ?? 0)
        ].joined(separator: "|")
    }

    private var displayText: String {
        guard allowsOnDeviceTranslation else {
            return itemTranslator.translated(source)
        }

        if allowsOnDemandTranslation,
           onDemandTranslationIdentity == translationIdentity,
           let onDemandTranslation {
            return onDemandTranslation
        }

        return translationService.displayText(
            for: source,
            using: itemTranslator
        )
    }

    var body: some View {
        Text(displayText)
            .id(translationService.cacheGeneration)
            .task(id: onDemandTaskID) {
                await loadOnDemandTranslationIfNeeded()
            }
    }

    private var onDemandTaskID: String {
        allowsOnDemandTranslation ? translationIdentity : "disabled"
    }

    private func loadOnDemandTranslationIfNeeded() async {
        guard allowsOnDeviceTranslation, allowsOnDemandTranslation else {
            onDemandTranslation = nil
            onDemandTranslationIdentity = nil
            return
        }

        let currentIdentity = translationIdentity
        onDemandTranslation = nil
        onDemandTranslationIdentity = nil

        let translatedText = await translationService.onDemandDisplayText(
            for: source,
            using: itemTranslator
        )

        guard !Task.isCancelled, currentIdentity == translationIdentity else {
            return
        }

        onDemandTranslation = translatedText
        onDemandTranslationIdentity = currentIdentity
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
