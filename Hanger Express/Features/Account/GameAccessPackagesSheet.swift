import SwiftUI

struct GameAccessPackagesSheet: View {
    let game: RSIGame
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @State private var itemTranslationState = HangarItemTranslationViewState()

    private var access: RSIGameAccess { appModel.snapshot?.gameAccess?.access(for: game) ?? .unknown }
    private var matches: [RSIGamePackageMatch]? { appModel.readyInventoryPresentation?.gameAccessPackages[game] }
    private var itemLanguage: String { HangarItemLanguage.resolved(forAppLanguageRawValue: appLanguageRawValue).rawValue }
    private var translator: HangarItemTranslator { itemTranslationState.translator(for: itemLanguage) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(game == .starCitizen ? "StarCitizenGameLogo" : "Squadron42GameLogo")
                            .renderingMode(.template)
                            .resizable().scaledToFit().frame(width: 36, height: 36)
                            .foregroundStyle(game == .starCitizen ? Color.blue : Color.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Game Access").font(.headline)
                            Text(accessLabel).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Access status comes from your last Account refresh.")
                }

                Section {
                    if let matches {
                        if matches.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "shippingbox")
                                    .font(.title).foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text("No matching game packages")
                                    .font(.headline)
                                Text(LocalizedStringKey(access == .granted
                                     ? "RSI confirms access, but no matching package was found in your saved Hangar."
                                     : "No package with this game was found in your saved Hangar."))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .accessibilityIdentifier("GameAccessPackagesEmpty")
                        } else {
                            ForEach(matches) { match in
                                packageRow(match)
                            }
                        }
                    } else if appModel.snapshot != nil {
                        ProgressView("Preparing inventory...")
                    } else {
                        Text("Refresh Hangar to find packages that include this game.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Game Packages")
                } footer: {
                    Text("Packages are matched from your saved Hangar contents. Refresh Hangar to update this list.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text(LocalizedStringKey(game.title)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: "\(itemLanguage)-\(appModel.itemTranslationDictionaryRefreshGeneration)") {
                await itemTranslationState.loadDictionary(for: itemLanguage,
                    refreshGeneration: appModel.itemTranslationDictionaryRefreshGeneration)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("GameAccessPackages-\(game.rawValue)")
    }

    private var accessLabel: LocalizedStringKey {
        switch access {
        case .granted: "Access active"
        case .notGranted: "No access"
        case .unknown: "Access unavailable"
        }
    }

    private func packageRow(_ match: RSIGamePackageMatch) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteThumbnailView(url: match.package.packageThumbnailURL,
                reloadToken: appModel.hangarFleetImageReloadToken,
                fallbackSystemImage: "shippingbox.fill", size: 48)
            VStack(alignment: .leading, spacing: 5) {
                HangarTranslatedText(source: match.package.title, itemTranslator: translator)
                    .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                Text(AppLocalizer.format("Pledge #%lld", match.package.id))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(match.accessItems.enumerated()), id: \.offset) { _, item in
                    HangarTranslatedText(source: item.title, itemTranslator: translator)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("GameAccessPackage-\(match.id)")
    }
}
