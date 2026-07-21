import Foundation
import SwiftUI
import UIKit

nonisolated enum FleetCardBaseSnapshotStyle: String, Hashable, Sendable {
    case hero
    case compact
}

nonisolated struct FleetCardBaseSnapshotRecipe: Hashable, Sendable {
    let style: FleetCardBaseSnapshotStyle
    let pointSize: CGSize
    let manufacturerName: String
    let backdropURL: URL?
    let logoURL: URL?

    init(
        style: FleetCardBaseSnapshotStyle,
        pointSize: CGSize,
        manufacturerName: String,
        backdropURL: URL?,
        logoURL: URL?
    ) {
        self.style = style
        self.pointSize = CGSize(
            width: max(1, pointSize.width.rounded(.up)),
            height: max(1, pointSize.height.rounded(.up))
        )
        self.manufacturerName = manufacturerName
        self.backdropURL = backdropURL
        self.logoURL = logoURL
    }

    nonisolated var cachePayload: String {
        [
            style.rawValue,
            "\(Int(pointSize.width))x\(Int(pointSize.height))",
            manufacturerName.fleetLogoSizingKey,
            backdropURL?.absoluteString ?? "no-backdrop",
            logoURL?.absoluteString ?? "no-logo"
        ].joined(separator: "|")
    }

    nonisolated var cornerRadius: CGFloat {
        switch style {
        case .hero:
            24
        case .compact:
            22
        }
    }

    nonisolated var logoMaxHeight: CGFloat {
        switch style {
        case .hero:
            54
        case .compact:
            50
        }
    }

    nonisolated var logoMaxWidth: CGFloat {
        switch style {
        case .hero:
            82
        case .compact:
            74
        }
    }

    nonisolated var logoTopPadding: CGFloat {
        switch style {
        case .hero:
            14
        case .compact:
            14
        }
    }

    nonisolated var logoTrailingPadding: CGFloat {
        switch style {
        case .hero:
            18
        case .compact:
            16
        }
    }

    nonisolated var adjustedLogoMaxWidth: CGFloat {
        logoMaxWidth * FleetManufacturerLogoSizing.widthMultiplier(for: manufacturerName)
    }

    nonisolated var logoTargetSize: CGSize {
        CGSize(width: logoMaxHeight * 6, height: logoMaxHeight * 3)
    }
}

struct CachedFleetCardBaseImage<Content: View>: View {
    let recipe: FleetCardBaseSnapshotRecipe
    let reloadToken: UUID?
    let maxRetryCount: Int
    let content: (CachedRemoteImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @State private var phase: CachedRemoteImagePhase = .empty

    init(
        recipe: FleetCardBaseSnapshotRecipe,
        reloadToken: UUID? = nil,
        maxRetryCount: Int = 5,
        @ViewBuilder content: @escaping (CachedRemoteImagePhase) -> Content
    ) {
        self.recipe = recipe
        self.reloadToken = reloadToken
        self.maxRetryCount = maxRetryCount
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: reloadTaskID) {
                await loadImage()
            }
    }

    private var reloadTaskID: String {
        [
            recipe.cachePayload,
            reloadToken?.uuidString ?? "none",
            "\(Int((displayScale * 100).rounded(.up)))"
        ].joined(separator: "|")
    }

    private func loadImage() async {
        guard recipe.pointSize.width > 1, recipe.pointSize.height > 1 else {
            return
        }

        phase = .empty

        do {
            let image = try await URLCachedImageStore.shared.fleetCardBaseImage(
                for: recipe,
                displayScale: displayScale,
                maxRetries: maxRetryCount
            )

            guard !Task.isCancelled else {
                return
            }

            phase = .success(Image(uiImage: image))
        } catch {
            guard !Task.isCancelled else {
                return
            }

            phase = .failure
        }
    }
}

struct FleetCardBaseSnapshotPlaceholder: View {
    let recipe: FleetCardBaseSnapshotRecipe
    var showsProgress = false

    var body: some View {
        FleetCardBaseSnapshotView(
            recipe: recipe,
            backdropImage: nil,
            logoImage: nil
        )
        .overlay {
            if showsProgress {
                ProgressView()
                    .tint(.white.opacity(0.86))
            }
        }
    }
}

enum FleetManufacturerLogoSizing {
    nonisolated static func widthMultiplier(for manufacturerName: String) -> CGFloat {
        switch manufacturerName.fleetLogoSizingKey {
        case "anvilaerospace":
            1.10
        case "aegisdynamics":
            0.765
        case "crusaderindustries":
            1.20
        case "mirai":
            0.935
        case "rsi", "robertsspaceindustries":
            0.765
        case "tumbril", "tumbrillandsystems":
            0.935
        default:
            0.85
        }
    }
}

@MainActor
enum FleetCardBaseSnapshotRenderer {
    static func render(
        recipe: FleetCardBaseSnapshotRecipe,
        backdropImage: UIImage?,
        logoImage: UIImage?,
        displayScale: CGFloat
    ) throws -> UIImage {
        let content = FleetCardBaseSnapshotView(
            recipe: recipe,
            backdropImage: backdropImage,
            logoImage: logoImage
        )
        .frame(width: recipe.pointSize.width, height: recipe.pointSize.height)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = max(displayScale, 1)
        renderer.proposedSize = ProposedViewSize(recipe.pointSize)

        guard let renderedImage = renderer.uiImage else {
            if let failedURL = recipe.backdropURL ?? recipe.logoURL {
                throw RemoteImageStoreError.unexpectedFailure(failedURL)
            }

            throw RemoteImageStoreError.invalidImageData(nil)
        }

        return renderedImage
    }
}

private struct FleetCardBaseSnapshotView: View {
    let recipe: FleetCardBaseSnapshotRecipe
    let backdropImage: UIImage?
    let logoImage: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundFill

            backdropLayer

            overlayGradient
                .clipShape(RoundedRectangle(cornerRadius: recipe.cornerRadius, style: .continuous))
        }
        .frame(width: recipe.pointSize.width, height: recipe.pointSize.height)
        .overlay {
            RoundedRectangle(cornerRadius: recipe.cornerRadius, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            logoOverlay
                .padding(.top, recipe.logoTopPadding)
                .padding(.trailing, recipe.logoTrailingPadding)
        }
        .clipShape(RoundedRectangle(cornerRadius: recipe.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var backgroundFill: some View {
        switch recipe.style {
        case .hero:
            RoundedRectangle(cornerRadius: recipe.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.12, blue: 0.17),
                            Color(red: 0.08, green: 0.19, blue: 0.27),
                            Color(red: 0.05, green: 0.28, blue: 0.32)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.cyan.opacity(0.12))
                        .frame(width: 180, height: 180)
                        .blur(radius: 10)
                        .offset(x: 48, y: -28)
                }
        case .compact:
            RoundedRectangle(cornerRadius: recipe.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.11, blue: 0.16),
                            Color(red: 0.07, green: 0.17, blue: 0.24),
                            Color(red: 0.05, green: 0.24, blue: 0.29)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    @ViewBuilder
    private var backdropLayer: some View {
        switch recipe.style {
        case .hero:
            ZStack {
                heroBackdropPlaceholder
                backdropContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .mask(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.42),
                        Color.black
                    ],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: 0.78, y: 0.5)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: recipe.cornerRadius, style: .continuous))
        case .compact:
            ZStack {
                compactBackdropPlaceholder
                backdropContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.2)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: recipe.cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    private var backdropContent: some View {
        if let backdropImage {
            Image(uiImage: backdropImage)
                .resizable()
                .scaledToFill()
                .frame(width: recipe.pointSize.width, height: recipe.pointSize.height)
                .clipped()
        }
    }

    @ViewBuilder
    private var logoOverlay: some View {
        if let logoImage {
            Image(uiImage: logoImage)
                .resizable()
                .scaledToFit()
                .frame(
                    maxWidth: recipe.adjustedLogoMaxWidth,
                    maxHeight: recipe.logoMaxHeight,
                    alignment: .trailing
                )
                .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 2)
                .compositingGroup()
        } else if recipe.logoURL != nil {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: min(recipe.logoMaxHeight * 0.5, 28), weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(width: recipe.logoMaxHeight, height: recipe.logoMaxHeight)
        }
    }

    @ViewBuilder
    private var overlayGradient: some View {
        switch recipe.style {
        case .hero:
            LinearGradient(
                colors: [
                    Color.black.opacity(0.72),
                    Color.black.opacity(0.48),
                    Color.black.opacity(0.08)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .compact:
            LinearGradient(
                colors: [
                    Color.black.opacity(0.82),
                    Color.black.opacity(0.64),
                    Color.black.opacity(0.34)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var strokeColor: Color {
        switch recipe.style {
        case .hero:
            Color.cyan.opacity(0.18)
        case .compact:
            Color.cyan.opacity(0.16)
        }
    }

    private var heroBackdropPlaceholder: some View {
        HStack {
            Spacer(minLength: 0)
            Image(systemName: "airplane")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(Color.white.opacity(0.16))
                .padding(.trailing, 24)
        }
    }

    private var compactBackdropPlaceholder: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Image(systemName: "airplane")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.16))
                    .padding(.trailing, 18)
                    .padding(.bottom, 20)
            }
        }
    }
}

private extension String {
    nonisolated var fleetLogoSizingKey: String {
        unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .localizedLowercase
    }
}
