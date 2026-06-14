import SwiftUI
import UIKit

struct DashboardTabView: View {
    let appModel: AppModel
    let snapshot: HangarSnapshot
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @State private var didCopyRefreshDebugReport = false

    private var appLanguage: AppLanguage {
        AppLanguage.resolved(from: appLanguageRawValue)
    }

    var body: some View {
        TabView(selection: selection) {
            HangarDashboardView(appModel: appModel, snapshot: snapshot)
                .tabItem {
                    Label("Hangar", systemImage: "shippingbox")
                }
                .tag(AppModel.Tab.hangar)

            FleetView(appModel: appModel, snapshot: snapshot)
                .tabItem {
                    Label("Fleet", systemImage: "airplane")
                }
                .tag(AppModel.Tab.fleet)

            BuybackView(appModel: appModel, snapshot: snapshot)
                .tabItem {
                    Label("Buy Back", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .tag(AppModel.Tab.buyback)

            AccountView(appModel: appModel, snapshot: snapshot)
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }
                .tag(AppModel.Tab.account)
        }
        .environment(\.locale, appLanguage.locale)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                RefreshPresentationInset(
                    presentation: appModel.refreshPresentation,
                    transientBanner: appModel.transientBanner
                )

                if let itemTranslationPreloadProgress = appModel.itemTranslationPreloadProgress {
                    ItemTranslationPreloadProgressCard(
                        progress: itemTranslationPreloadProgress,
                        logEntries: appModel.itemTranslationPreloadLogEntries,
                        onCancel: {
                            appModel.cancelItemTranslationPreload()
                        }
                    )
                        .padding(.horizontal)
                        .padding(.top, 4)
                }
            }
        }
        .animation(.snappy, value: appModel.transientBanner)
        .animation(.snappy, value: appModel.itemTranslationPreloadProgress)
        .overlay {
            if let message = appModel.lastRefreshErrorMessage {
                RefreshFailureOverlay(
                    message: message,
                    onDismiss: {
                        appModel.dismissRefreshError()
                    },
                    onCopyLogs: copyRefreshDebugReport
                )
            }
        }
        .alert(item: reauthenticationPromptBinding) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .default(Text("Sign In Again")) {
                    Task {
                        await appModel.beginReauthentication()
                    }
                },
                secondaryButton: .cancel(Text("Later")) {
                    appModel.dismissReauthenticationPrompt()
                }
            )
        }
        .alert("Refresh Debug Report Copied", isPresented: $didCopyRefreshDebugReport) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The refresh diagnostics log was copied to the clipboard so the tester can send it to you.")
        }
        .alert(item: itemTranslationPreprocessPromptBinding) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .default(Text(prompt.primaryActionTitle)) {
                    appModel.beginItemTranslationPreprocessing()
                },
                secondaryButton: .cancel(Text(prompt.secondaryActionTitle)) {
                    appModel.dismissItemTranslationPreprocessPrompt()
                }
            )
        }
        .sheet(item: versionRefreshPromptBinding) { prompt in
            VersionRefreshPromptSheet(
                prompt: prompt,
                onRefreshNow: {
                    appModel.dismissVersionRefreshPrompt()
                    Task {
                        await appModel.refresh(scope: .full)
                    }
                },
                onLater: {
                    appModel.dismissVersionRefreshPrompt()
                }
            )
            .presentationDetents([.height(240)])
            .presentationDragIndicator(.visible)
        }
    }

    private var selection: Binding<AppModel.Tab> {
        Binding(
            get: { appModel.selectedTab },
            set: { appModel.selectedTab = $0 }
        )
    }

    private var reauthenticationPromptBinding: Binding<AppModel.ReauthenticationPrompt?> {
        Binding(
            get: { appModel.reauthenticationPrompt },
            set: { newValue in
                guard newValue == nil else {
                    return
                }

                appModel.dismissReauthenticationPrompt()
            }
        )
    }

    private var itemTranslationPreprocessPromptBinding: Binding<AppModel.ItemTranslationPreprocessPrompt?> {
        Binding(
            get: { appModel.itemTranslationPreprocessPrompt },
            set: { newValue in
                if newValue == nil {
                    appModel.dismissItemTranslationPreprocessPrompt()
                }
            }
        )
    }

    private var versionRefreshPromptBinding: Binding<AppModel.VersionRefreshPrompt?> {
        Binding(
            get: { appModel.versionRefreshPrompt },
            set: { newValue in
                if newValue == nil {
                    appModel.dismissVersionRefreshPrompt()
                }
            }
        )
    }

    private var refreshDebugReport: String {
        RefreshDebugReportBuilder.build(
            entries: appModel.refreshDiagnostics.entries,
            scope: appModel.lastRefreshErrorScope,
            errorMessage: appModel.lastRefreshErrorMessage
        )
    }

    private func copyRefreshDebugReport() {
        guard !refreshDebugReport.isEmpty else {
            return
        }

        UIPasteboard.general.string = refreshDebugReport
        didCopyRefreshDebugReport = true
    }
}

private struct ItemTranslationPreloadProgressCard: View {
    let progress: AppModel.ItemTranslationPreloadProgress
    let logEntries: [AppModel.ItemTranslationPreloadLogEntry]
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(progress.title, systemImage: iconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let fractionCompleted = progress.fractionCompleted {
                    Text(fractionCompleted, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            progressBar

            Text(progress.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !logEntries.isEmpty {
                Divider()
                    .opacity(0.5)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(logEntries.suffix(6)) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.occurredAt, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 56, alignment: .leading)

                            Text(entry.message)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .textSelection(.enabled)
            }

            if progress.showsCancelAction {
                Button(role: .cancel, action: onCancel) {
                    Label(progress.cancelActionTitle, systemImage: "xmark.circle")
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(iconColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(iconColor.opacity(0.22))
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fractionCompleted = progress.fractionCompleted {
            ProgressView(value: fractionCompleted, total: 1)
                .tint(iconColor)
        } else {
            ProgressView()
                .tint(iconColor)
                .controlSize(.small)
        }
    }

    private var iconName: String {
        switch progress.phase {
        case .finished:
            return "checkmark.circle.fill"
        case .unavailable, .failed, .timedOut:
            return "exclamationmark.triangle.fill"
        case .preparing, .translating:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var iconColor: Color {
        switch progress.phase {
        case .finished:
            return .green
        case .unavailable, .failed, .timedOut:
            return .orange
        case .preparing, .translating:
            return .blue
        }
    }
}

private struct VersionRefreshPromptSheet: View {
    let prompt: AppModel.VersionRefreshPrompt
    let onRefreshNow: () -> Void
    let onLater: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(prompt.title)
                    .font(.title3.bold())

                Text(prompt.message)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Later", action: onLater)
                        .buttonStyle(.bordered)

                    Button("Refresh Now", action: onRefreshNow)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct RefreshFailureOverlay: View {
    let message: String
    let onDismiss: () -> Void
    let onCopyLogs: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Text("Refresh Failed")
                    .font(.title3.bold())

                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    Button("OK", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                    Button("Copy Logs", action: onCopyLogs)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(22)
            .frame(maxWidth: 360, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
            .padding(.horizontal, 24)
        }
        .transition(.opacity.combined(with: .scale))
    }
}

enum RefreshDebugReportBuilder {
    static func build(
        entries: [RefreshDiagnosticsStore.Entry],
        scope: AppModel.RefreshScope?,
        errorMessage: String?
    ) -> String {
        let trimmedErrorMessage = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(entries.isEmpty && (trimmedErrorMessage?.isEmpty != false)) else {
            return ""
        }

        var sections: [String] = [
            "Hangar Express Refresh Debug Report",
            "Generated: \(Date().formatted(date: .complete, time: .standard))",
            "App: \(appVersionIdentifier())",
            "Device: \(UIDevice.current.model)",
            "iOS: \(UIDevice.current.systemVersion)",
            "Refresh Scope: \(scopeLabel(scope))"
        ]

        if let trimmedErrorMessage, !trimmedErrorMessage.isEmpty {
            sections.append("")
            sections.append("Visible Error")
            sections.append(trimmedErrorMessage)
        }

        if !entries.isEmpty {
            sections.append("")
            sections.append("Diagnostics")
            sections.append(
                entries.map { entry in
                    let baseLine = "[\(entry.timestampLabel)] \(entry.level.rawValue) \(entry.stage)\n\(entry.summary)"
                    guard let detail = entry.detail, !detail.isEmpty else {
                        return baseLine
                    }

                    return "\(baseLine)\n\(detail)"
                }
                .joined(separator: "\n\n")
            )
        }

        return sections.joined(separator: "\n")
    }

    private static func appVersionIdentifier() -> String {
        let shortVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let buildVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch (shortVersion, buildVersion) {
        case let (.some(shortVersion), .some(buildVersion))
            where !shortVersion.isEmpty && !buildVersion.isEmpty:
            return "\(shortVersion) (\(buildVersion))"
        case let (.some(shortVersion), _) where !shortVersion.isEmpty:
            return shortVersion
        case let (_, .some(buildVersion)) where !buildVersion.isEmpty:
            return buildVersion
        default:
            return "Unavailable"
        }
    }

    private static func scopeLabel(_ scope: AppModel.RefreshScope?) -> String {
        switch scope {
        case .full:
            return "Full"
        case .hangar:
            return "Hangar"
        case .buyback:
            return "Buy Back"
        case .hangarLog:
            return "Hangar Log"
        case .account:
            return "Account"
        case nil:
            return "Unknown"
        }
    }
}
