import SwiftUI

struct RefreshProgressCard: View {
    let progress: RefreshProgress
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.stepLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if let fractionCompleted = progress.displayFractionCompleted {
                    Text(fractionCompleted, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text(progress.stage.title)
                .font(compact ? .headline : .title3.bold())

            progressBar

            Text(progress.detail)
                .font(compact ? .caption : .body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 14 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: compact ? 18 : 24, style: .continuous))
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fractionCompleted = progress.displayFractionCompleted {
            SmoothLinearProgressBar(value: fractionCompleted, compact: compact)
        } else {
            ProgressView()
                .tint(.blue)
        }
    }
}

struct MinimalRefreshProgressView: View {
    let progress: RefreshProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progress.stage.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            progressBar

            Text(progress.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 220, alignment: .leading)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fractionCompleted = progress.displayFractionCompleted {
            SmoothLinearProgressBar(value: fractionCompleted, compact: true)
        } else {
            ProgressView()
                .tint(.blue)
                .controlSize(.small)
        }
    }
}

struct ConcurrentRefreshProgressStrip: View {
    let entries: [AppModel.ConcurrentRefreshEntry]
    var compact = false

    var body: some View {
        if compact {
            HStack(alignment: .top, spacing: 8) {
                progressTiles
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                progressTiles
            }
        }
    }

    private var progressTiles: some View {
        ForEach(entries) { entry in
            ConcurrentRefreshProgressTile(entry: entry, compact: compact)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ConcurrentRefreshProgressTile: View {
    let entry: AppModel.ConcurrentRefreshEntry
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(alignment: .center, spacing: compact ? 8 : 10) {
                Image(systemName: iconName)
                    .font(compact ? .caption.weight(.bold) : .title3.weight(.bold))
                    .foregroundStyle(iconColor)
                    .symbolRenderingMode(.hierarchical)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.area.title)
                        .font(compact ? .caption.weight(.bold) : .headline.weight(.bold))
                        .lineLimit(1)

                    Text(statusText)
                        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                        .foregroundStyle(entry.isComplete ? .green : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if entry.isComplete {
                Text(AppLocalizer.format("%@ complete.", entry.area.title))
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .leading)))
            } else {
                progressBar

                Text(entry.progress.detail)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 3 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .leading)))
            }
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: compact ? 16 : 20, style: .continuous)
        )
        .animation(.smooth(duration: 0.28), value: entry.isComplete)
    }

    private var iconName: String {
        entry.isComplete ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
    }

    private var iconColor: Color {
        entry.isComplete ? .green : .blue
    }

    private var statusText: String {
        entry.isComplete ? AppLocalizer.string("Complete") : entry.progress.stage.title
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fractionCompleted = entry.progress.displayFractionCompleted {
            SmoothLinearProgressBar(value: fractionCompleted, compact: compact)
        } else {
            ProgressView()
                .tint(.blue)
                .controlSize(compact ? .small : .regular)
        }
    }
}

private extension RefreshProgress {
    var displayFractionCompleted: Double? {
        guard let baseFraction = fractionCompleted, stepCount > 0 else {
            return fractionCompleted
        }

        let boundedStep = min(max(stepNumber, 1), stepCount)
        let boundedStepFraction = min(max(baseFraction, 0), 1)
        return (Double(boundedStep - 1) + boundedStepFraction) / Double(stepCount)
    }
}

private struct SmoothLinearProgressBar: View {
    let value: Double
    let compact: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedValue: Double = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.secondary.opacity(0.18))

                Capsule(style: .continuous)
                    .fill(.blue.gradient)
                    .frame(width: proxy.size.width * displayedValue)
                    .shadow(color: .blue.opacity(compact ? 0.18 : 0.24), radius: compact ? 2 : 4, y: 1)
            }
        }
        .frame(height: compact ? 4 : 6)
        .onAppear {
            guard !reduceMotion else {
                displayedValue = clampedValue
                return
            }

            displayedValue = 0
            withAnimation(.smooth(duration: animationDuration(from: 0, to: clampedValue))) {
                displayedValue = clampedValue
            }
        }
        .onChange(of: clampedValue) { oldValue, newValue in
            let targetValue = max(displayedValue, newValue)
            guard !reduceMotion else {
                displayedValue = targetValue
                return
            }

            withAnimation(.smooth(duration: animationDuration(from: max(displayedValue, oldValue), to: targetValue))) {
                displayedValue = targetValue
            }
        }
    }

    private var clampedValue: Double {
        min(max(value, 0), 1)
    }

    private func animationDuration(from oldValue: Double, to newValue: Double) -> TimeInterval {
        let delta = abs(newValue - oldValue)
        return min(max(0.35, 0.35 + delta * 0.85), 0.95)
    }
}

struct TransientBannerView: View {
    let banner: AppModel.TransientBanner

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.headline.weight(.bold))
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(banner.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(iconColor.opacity(0.25))
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private var iconName: String {
        switch banner.style {
        case .success:
            return "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch banner.style {
        case .success:
            return .green
        }
    }

    private var backgroundColor: some ShapeStyle {
        switch banner.style {
        case .success:
            return Color.green.opacity(0.14)
        }
    }
}
