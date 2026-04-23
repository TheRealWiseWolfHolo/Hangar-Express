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

                if let fractionCompleted = progress.fractionCompleted {
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
        if let fractionCompleted = progress.fractionCompleted {
            ProgressView(value: fractionCompleted)
                .tint(.blue)
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
        if let fractionCompleted = progress.fractionCompleted {
            ProgressView(value: fractionCompleted)
                .tint(.blue)
                .controlSize(.small)
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
        HStack(alignment: .top, spacing: compact ? 8 : 12) {
            ForEach(entries) { entry in
                ConcurrentRefreshProgressTile(entry: entry, compact: compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ConcurrentRefreshProgressTile: View {
    let entry: AppModel.ConcurrentRefreshEntry
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text(entry.area.title)
                .font(compact ? .caption.weight(.bold) : .headline.weight(.bold))
                .lineLimit(1)

            Text(entry.progress.stage.title)
                .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            progressBar

            Text(entry.progress.detail)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 3 : 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: compact ? 16 : 20, style: .continuous)
        )
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fractionCompleted = entry.progress.fractionCompleted {
            ProgressView(value: fractionCompleted)
                .tint(.blue)
                .controlSize(compact ? .small : .regular)
        } else {
            ProgressView()
                .tint(.blue)
                .controlSize(compact ? .small : .regular)
        }
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
