import SwiftUI

struct ReferralRewardDestinationView: View {
    let selection: ReferralRewardDestination
    let appModel: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @State private var translations = HangarItemTranslationViewState()
    private var itemLanguage: String { HangarItemLanguage.resolved(forAppLanguageRawValue: language).rawValue }
    private var translator: HangarItemTranslator { translations.translator(for: itemLanguage) }

    var body: some View {
        Group {
        if selection.groups.count == 1, let group = selection.groups.first {
            detail(group)
        } else {
            List {
                Section {
                    ForEach(selection.groups) { group in
                        NavigationLink { detail(group) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(translator.translated(group.representative.title)).font(.headline)
                                Text(AppLocalizer.format("Pledge #%lld", group.representative.id))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                        .accessibilityIdentifier("referrals.match.\(group.id)")
                    }
                } header: {
                    Text(AppLocalizer.string("Choose a Hangar item"))
                } footer: {
                    Text(AppLocalizer.string("More than one saved Hangar entry matches this reward."))
                }
            }
            .navigationTitle(selection.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        }
        .task(id: "\(itemLanguage)-\(appModel.itemTranslationDictionaryRefreshGeneration)") {
            await translations.loadDictionary(for: itemLanguage,
                refreshGeneration: appModel.itemTranslationDictionaryRefreshGeneration)
        }
    }

    private func detail(_ group: GroupedHangarPackage) -> some View {
        HangarPackageDetailView(appModel: appModel, packageGroup: group,
                               itemTranslator: translator, reloadToken: appModel.hangarFleetImageReloadToken)
    }
}
