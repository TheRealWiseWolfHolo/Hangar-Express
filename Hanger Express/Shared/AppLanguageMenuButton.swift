import SwiftUI

struct AppLanguageMenuButton: View {
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue

    private var selectedLanguage: AppLanguage {
        AppLanguage.resolved(from: appLanguageRawValue)
    }

    var body: some View {
        Menu {
            Picker("Language", selection: $appLanguageRawValue) {
                ForEach(AppLanguage.allCases) { language in
                    language.label
                        .tag(language.rawValue)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(selectedLanguage.shortLabel)
                    .font(.caption.weight(.semibold))
            }
        }
        .accessibilityLabel(Text("Language"))
    }
}
