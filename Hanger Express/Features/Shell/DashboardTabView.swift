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
        GeometryReader { geometry in
            content(in: geometry)
        }
    }

    private func content(in geometry: GeometryProxy) -> some View {
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
                    if shouldShowItemTranslationPreloadCard(
                        for: itemTranslationPreloadProgress,
                        in: geometry
                    ) {
                        ItemTranslationPreloadProgressCard(
                            progress: itemTranslationPreloadProgress,
                            onDownloadModel: {
                                Task {
                                    await appModel.downloadItemTranslationModel()
                                }
                            },
                            onCancel: {
                                appModel.cancelItemTranslationPreload()
                            }
                        )
                            .padding(.horizontal)
                            .padding(.top, 4)
                    }
                }
            }
        }
        .animation(.snappy, value: appModel.transientBanner)
        .animation(.snappy, value: appModel.itemTranslationPreloadProgress)
        .animation(.snappy, value: appModel.previewsTranslationLoadingBar)
        .overlay(alignment: .top) {
            if let itemTranslationPreloadProgress = appModel.itemTranslationPreloadProgress,
               itemTranslationPreloadProgress.prefersDynamicIslandProgress,
               let metrics = DynamicIslandProgressMetrics(in: geometry) {
                DynamicIslandTranslationProgressIndicator(
                    progress: itemTranslationPreloadProgress,
                    metrics: metrics
                )
                .transition(.opacity)
            } else if appModel.previewsTranslationLoadingBar,
                      let metrics = DynamicIslandProgressMetrics(in: geometry) {
                DynamicIslandTranslationProgressPreview(metrics: metrics)
                    .transition(.opacity)
            }
        }
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
            .presentationDetents(prompt.updateNotes.isEmpty ? [.height(240)] : [.height(430), .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func shouldShowItemTranslationPreloadCard(
        for progress: AppModel.ItemTranslationPreloadProgress,
        in geometry: GeometryProxy
    ) -> Bool {
        guard progress.prefersDynamicIslandProgress else {
            return true
        }

        return DynamicIslandProgressMetrics(in: geometry) == nil
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

private struct DynamicIslandTranslationProgressIndicator: View {
    private static let strokePixelWidth: CGFloat = 16
    private static let verticalPixelAdjustment: CGFloat = 5
    private static let indeterminateSegmentLength = 0.28
    private static let indeterminateDuration: TimeInterval = 1.15

    let progress: AppModel.ItemTranslationPreloadProgress
    let metrics: DynamicIslandProgressMetrics
    @Environment(\.displayScale) private var displayScale
    @State private var indeterminateRotation = 0.0

    var body: some View {
        ZStack {
            outlineShape
                .stroke(
                    Color.primary.opacity(0.18),
                    style: strokeStyle
                )

            if let fractionCompleted = boundedFractionCompleted {
                DynamicIslandProgressSegmentShape(
                    startFraction: 0,
                    endFraction: fractionCompleted
                )
                    .stroke(
                        progress.presentationTint,
                        style: strokeStyle
                    )
            } else {
                DynamicIslandProgressSegmentShape(
                    startFraction: CGFloat(indeterminateRotation / 360),
                    endFraction: CGFloat(indeterminateRotation / 360 + Self.indeterminateSegmentLength)
                )
                    .stroke(
                        progress.presentationTint,
                        style: strokeStyle
                    )
            }
        }
        .frame(width: progressRingSize.width, height: progressRingSize.height)
        .position(x: metrics.centerX, y: metrics.centerY - verticalOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shadow(color: progress.presentationTint.opacity(0.3), radius: 3)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(progress.title))
        .accessibilityValue(Text(accessibilityValue))
        .onAppear(perform: startIndeterminateAnimationIfNeeded)
        .onChange(of: progress.fractionCompleted) { _, _ in
            startIndeterminateAnimationIfNeeded()
        }
    }

    private var outlineShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: progressRingSize.height / 2, style: .continuous)
    }

    private var progressRingSize: CGSize {
        metrics.islandSize
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(
            lineWidth: strokeLineWidth,
            lineCap: .round,
            lineJoin: .round
        )
    }

    private var strokeLineWidth: CGFloat {
        Self.strokePixelWidth / max(displayScale, 1)
    }

    private var verticalOffset: CGFloat {
        Self.verticalPixelAdjustment / max(displayScale, 1)
    }

    private var boundedFractionCompleted: CGFloat? {
        guard let fractionCompleted = progress.fractionCompleted else {
            return nil
        }

        return CGFloat(min(max(fractionCompleted, 0), 1))
    }

    private var accessibilityValue: String {
        if let fractionCompleted = progress.fractionCompleted {
            return fractionCompleted.formatted(.percent.precision(.fractionLength(0)))
        }

        return progress.detail
    }

    private func startIndeterminateAnimationIfNeeded() {
        guard progress.fractionCompleted == nil else {
            return
        }

        indeterminateRotation = 0
        withAnimation(.linear(duration: Self.indeterminateDuration).repeatForever(autoreverses: false)) {
            indeterminateRotation = 360
        }
    }
}

private struct DynamicIslandProgressSegmentShape: Shape {
    var startFraction: CGFloat
    var endFraction: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            AnimatablePair(startFraction, endFraction)
        }
        set {
            startFraction = newValue.first
            endFraction = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let points = roundedRectanglePerimeterPoints(in: rect)
        guard points.count > 1 else {
            return Path()
        }

        let segmentLengths = segmentLengths(for: points)
        let totalLength = segmentLengths.reduce(0, +)
        guard totalLength > 0 else {
            return Path()
        }

        let normalizedStart = normalized(startFraction)
        let normalizedEnd = normalized(endFraction)

        if endFraction - startFraction >= 1 {
            return partialPath(
                from: 0,
                to: totalLength,
                points: points,
                segmentLengths: segmentLengths
            )
        }

        if normalizedStart <= normalizedEnd {
            return partialPath(
                from: normalizedStart * totalLength,
                to: normalizedEnd * totalLength,
                points: points,
                segmentLengths: segmentLengths
            )
        }

        var path = partialPath(
            from: normalizedStart * totalLength,
            to: totalLength,
            points: points,
            segmentLengths: segmentLengths
        )
        path.addPath(
            partialPath(
                from: 0,
                to: normalizedEnd * totalLength,
                points: points,
                segmentLengths: segmentLengths
            )
        )
        return path
    }

    private func normalized(_ value: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private func roundedRectanglePerimeterPoints(in rect: CGRect) -> [CGPoint] {
        let radius = min(rect.height / 2, rect.width / 2)
        let sampleCount = 12
        var points: [CGPoint] = [
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX - radius, y: rect.minY)
        ]

        appendArcPoints(
            to: &points,
            center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: 0,
            sampleCount: sampleCount
        )
        points.append(CGPoint(x: rect.maxX, y: rect.maxY - radius))
        appendArcPoints(
            to: &points,
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: 0,
            endAngle: .pi / 2,
            sampleCount: sampleCount
        )
        points.append(CGPoint(x: rect.minX + radius, y: rect.maxY))
        appendArcPoints(
            to: &points,
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .pi / 2,
            endAngle: .pi,
            sampleCount: sampleCount
        )
        points.append(CGPoint(x: rect.minX, y: rect.minY + radius))
        appendArcPoints(
            to: &points,
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .pi,
            endAngle: .pi * 3 / 2,
            sampleCount: sampleCount
        )
        points.append(CGPoint(x: rect.midX, y: rect.minY))
        return points
    }

    private func appendArcPoints(
        to points: inout [CGPoint],
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        sampleCount: Int
    ) {
        guard sampleCount > 0 else {
            return
        }

        for index in 1 ... sampleCount {
            let progress = CGFloat(index) / CGFloat(sampleCount)
            let angle = startAngle + (endAngle - startAngle) * progress
            points.append(
                CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
            )
        }
    }

    private func segmentLengths(for points: [CGPoint]) -> [CGFloat] {
        zip(points, points.dropFirst()).map { start, end in
            hypot(end.x - start.x, end.y - start.y)
        }
    }

    private func partialPath(
        from startDistance: CGFloat,
        to endDistance: CGFloat,
        points: [CGPoint],
        segmentLengths: [CGFloat]
    ) -> Path {
        var path = Path()
        var traversedDistance: CGFloat = 0
        var didMove = false
        var previousPoint: CGPoint?

        for index in segmentLengths.indices {
            let segmentLength = segmentLengths[index]
            let nextDistance = traversedDistance + segmentLength
            defer {
                traversedDistance = nextDistance
            }

            guard nextDistance >= startDistance,
                  traversedDistance <= endDistance,
                  segmentLength > 0 else {
                continue
            }

            let startPoint = points[index]
            let endPoint = points[index + 1]
            let localStart = max(startDistance - traversedDistance, 0) / segmentLength
            let localEnd = min(endDistance - traversedDistance, segmentLength) / segmentLength
            guard localEnd >= localStart else {
                continue
            }

            let segmentStart = interpolatedPoint(from: startPoint, to: endPoint, progress: localStart)
            let segmentEnd = interpolatedPoint(from: startPoint, to: endPoint, progress: localEnd)

            if !didMove {
                path.move(to: segmentStart)
                didMove = true
            } else if previousPoint != segmentStart {
                path.addLine(to: segmentStart)
            }

            path.addLine(to: segmentEnd)
            previousPoint = segmentEnd
        }

        return path
    }

    private func interpolatedPoint(from start: CGPoint, to end: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }
}

private struct DynamicIslandTranslationProgressPreview: View {
    let metrics: DynamicIslandProgressMetrics

    var body: some View {
        DynamicIslandTranslationProgressIndicator(
            progress: AppModel.ItemTranslationPreloadProgress(
                language: .simplifiedChinese,
                phase: .translating,
                completedUnitCount: 72,
                totalUnitCount: 100
            ),
            metrics: metrics
        )
    }
}

private struct DynamicIslandProgressMetrics {
    // Apple exposes Dynamic Island content through ActivityKit/WidgetKit, not an in-app cutout frame.
    private static let minimumDynamicIslandTopSafeArea: CGFloat = 51
    private static let islandSize = CGSize(width: 126, height: 38)
    private static let islandVerticalOffset: CGFloat = 3

    let centerX: CGFloat
    let centerY: CGFloat
    let islandSize: CGSize

    init?(in geometry: GeometryProxy) {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            return nil
        }

        let topSafeArea = geometry.safeAreaInsets.top
        guard topSafeArea >= Self.minimumDynamicIslandTopSafeArea,
              geometry.size.width >= Self.islandSize.width else {
            return nil
        }

        centerX = geometry.size.width / 2
        centerY = topSafeArea / 2 + Self.islandVerticalOffset
        islandSize = Self.islandSize
    }
}

private extension AppModel.ItemTranslationPreloadProgress {
    var prefersDynamicIslandProgress: Bool {
        switch phase {
        case .preparing, .translating, .finished:
            return true
        case .downloadRequired, .unavailable, .failed, .timedOut:
            return false
        }
    }

    var presentationTint: Color {
        switch phase {
        case .finished:
            return .green
        case .downloadRequired, .unavailable, .failed, .timedOut:
            return .orange
        case .preparing, .translating:
            return .blue
        }
    }
}

private struct ItemTranslationPreloadProgressCard: View {
    let progress: AppModel.ItemTranslationPreloadProgress
    let onDownloadModel: () -> Void
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

            if progress.showsDownloadModelAction || progress.showsCancelAction {
                HStack(spacing: 8) {
                    if progress.showsDownloadModelAction {
                        Button(action: onDownloadModel) {
                            Label(progress.downloadModelActionTitle, systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if progress.showsCancelAction {
                        Button(role: .cancel, action: onCancel) {
                            Label(progress.cancelActionTitle, systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.caption.weight(.semibold))
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
        case .downloadRequired:
            return "arrow.down.circle.fill"
        case .unavailable, .failed, .timedOut:
            return "exclamationmark.triangle.fill"
        case .preparing, .translating:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var iconColor: Color {
        progress.presentationTint
    }
}

private struct VersionRefreshPromptSheet: View {
    let prompt: AppModel.VersionRefreshPrompt
    let onRefreshNow: () -> Void
    let onLater: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(prompt.title)
                            .font(.title3.bold())

                        Text(prompt.message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !prompt.updateNotes.isEmpty {
                            updateNotesSection
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                Divider()

                HStack(spacing: 12) {
                    Button("Later", action: onLater)
                        .buttonStyle(.bordered)

                    Button("Refresh Now", action: onRefreshNow)
                        .buttonStyle(.borderedProminent)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var updateNotesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt.updateNotesTitle)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(prompt.updateNotes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.top, 3)

                        Text(note)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
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
