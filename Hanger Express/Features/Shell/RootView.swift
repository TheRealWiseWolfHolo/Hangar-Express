import SwiftUI

struct RootView: View {
    let appModel: AppModel

    var body: some View {
        ZStack {
            Group {
                if appModel.session == nil {
                    PlanningLandingView(appModel: appModel)
                } else {
                    switch appModel.loadState {
                    case .idle, .loading:
                        NavigationStack {
                            VStack(spacing: 24) {
                                RefreshProgressCard(progress: appModel.refreshProgress ?? fallbackProgress)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                            .navigationTitle("Loading")
                        }
                    case let .loaded(snapshot):
                        DashboardTabView(appModel: appModel, snapshot: snapshot)
                    case let .failed(message):
                        NavigationStack {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Refresh failed")
                                    .font(.title2.bold())
                                Text(message)
                                    .foregroundStyle(.secondary)

                                Button("Try Again") {
                                    Task {
                                        await appModel.refresh()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding()
                            .navigationTitle("Connection")
                        }
                    }
                }
            }

            if let startupActivity = appModel.startupActivity {
                StartupWarmupOverlay(
                    title: startupActivity.title,
                    detail: startupActivity.detail
                )
            }
        }
    }

    private var fallbackProgress: RefreshProgress {
        RefreshProgress(
            stage: .preparingSession,
            stepNumber: 1,
            stepCount: 4,
            detail: "Starting the hangar refresh.",
            completedUnitCount: 0,
            totalUnitCount: nil
        )
    }
}

struct StartupWarmupOverlay: View {
    let title: String
    let detail: String
    @State private var animatePulse = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.cyan.opacity(0.35),
                                    Color.blue.opacity(0.15)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 86, height: 86)
                        .scaleEffect(animatePulse ? 1.04 : 0.94)
                        .opacity(animatePulse ? 0.95 : 0.6)

                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.25)
                }

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(.white)

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08))
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 28, y: 18)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                animatePulse = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}
