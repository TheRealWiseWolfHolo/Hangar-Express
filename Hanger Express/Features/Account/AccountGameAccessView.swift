import SwiftUI

struct AccountGameAccessView: View {
    @Environment(\.colorScheme) private var colorScheme
    let summary: RSIGameAccessSummary?

    var body: some View {
        let starCitizenActive = access(for: .starCitizen) == .granted
        let squadron42Active = access(for: .squadron42) == .granted
        let isDark = colorScheme == .dark
        let blueLight = (isDark
            ? Color(red: 0.07, green: 0.52, blue: 1.00)
            : Color(red: 0.04, green: 0.42, blue: 1.00))
            .opacity(starCitizenActive ? (isDark ? 0.40 : 0.52) : (isDark ? 0.08 : 0.06))
        let greenLight = (isDark
            ? Color(red: 0.07, green: 0.72, blue: 0.43)
            : Color(red: 0.00, green: 0.72, blue: 0.31))
            .opacity(squadron42Active ? (isDark ? 0.38 : 0.52) : (isDark ? 0.08 : 0.06))
        let glassShape = UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: 0,
                bottomLeading: 24,
                bottomTrailing: 24,
                topTrailing: 0
            ),
            style: .continuous
        )

        HStack(spacing: 0) {
            gameHalf(for: .starCitizen)

            Rectangle()
                .fill(Color.primary.opacity(0.22))
                .frame(width: 1)
                .padding(.vertical, 7)
                .accessibilityHidden(true)

            gameHalf(for: .squadron42)
        }
        .background {
            Rectangle()
                .fill(Color.clear)
                .glassEffect(.regular, in: glassShape)
                .overlay {
                    HStack(spacing: 0) {
                        Rectangle().fill(blueLight)
                        Rectangle().fill(greenLight)
                    }
                    .clipShape(glassShape)
                }
                .overlay {
                    glassShape.strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(colorScheme == .dark ? 0.38 : 0.30), location: 0),
                                .init(color: Color.cyan.opacity(starCitizenActive ? 0.30 : 0.10), location: 0.26),
                                .init(color: Color.white.opacity(0.16), location: 0.5),
                                .init(color: Color.green.opacity(squadron42Active ? 0.28 : 0.10), location: 0.75),
                                .init(color: Color.white.opacity(colorScheme == .dark ? 0.34 : 0.26), location: 1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
                .overlay {
                    glassShape.strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.10 : 0.18),
                        lineWidth: 0.5
                    )
                    .padding(1.5)
                }
        }
    }

    private func access(for game: RSIGame) -> RSIGameAccess {
        summary?.access(for: game) ?? .unknown
    }

    private func gameHalf(for game: RSIGame) -> some View {
        let access = access(for: game)
        let isGranted = access == .granted
        let titleKey = LocalizedStringKey(game.title)
        return HStack(spacing: 8) {
            Image(game == .starCitizen ? "StarCitizenGameLogo" : "Squadron42GameLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(isGranted ? Color.primary : Color.secondary)
                .opacity(isGranted ? 1 : 0.48)
                .accessibilityHidden(true)

            Text(titleKey)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isGranted ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(titleKey))
        .accessibilityValue(Text(statusLabel(for: access)))
    }

    private func statusLabel(for access: RSIGameAccess) -> LocalizedStringKey {
        switch access {
        case .granted:
            "Access active"
        case .notGranted:
            "No access"
        case .unknown:
            "Access unavailable"
        }
    }
}
