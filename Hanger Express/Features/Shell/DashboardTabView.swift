import SwiftUI
import UIKit

struct DashboardTabView: View {
    let appModel: AppModel
    let snapshot: HangarSnapshot
    @State private var didCopyRefreshDebugReport = false

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
        .safeAreaInset(edge: .top) {
            if appModel.transientBanner != nil
                || !appModel.concurrentRefreshEntries.isEmpty
                || appModel.refreshProgress != nil
            {
                VStack(spacing: 8) {
                    if let banner = appModel.transientBanner {
                        TransientBannerView(banner: banner)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }

                    if !appModel.concurrentRefreshEntries.isEmpty {
                        ConcurrentRefreshProgressStrip(
                            entries: appModel.concurrentRefreshEntries,
                            compact: true
                        )
                        .padding(.horizontal)
                    } else if let progress = appModel.refreshProgress {
                        Group {
                            if appModel.refreshIndicatorStyle == .compactTopLeading {
                                HStack {
                                    MinimalRefreshProgressView(progress: progress)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, 4)
                            } else {
                                RefreshProgressCard(progress: progress, compact: true)
                                    .padding(.horizontal)
                                    .padding(.top, 8)
                            }
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: appModel.refreshProgress)
        .animation(.snappy, value: appModel.concurrentRefreshEntries)
        .animation(.snappy, value: appModel.transientBanner)
        .animation(.snappy, value: appModel.refreshIndicatorStyle == .compactTopLeading)
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
