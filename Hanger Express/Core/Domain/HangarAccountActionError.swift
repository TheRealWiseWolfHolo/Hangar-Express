import Foundation

enum HangarAccountActionError: Error, LocalizedError, Sendable, Equatable {
    case actionInProgress
    case missingSession
    case missingStoredPassword
    case invalidMeltQuantity(maximum: Int)
    case meltTimedOut(timeoutSeconds: Int)
    case partialMelt(completedCount: Int, requestedCount: Int, message: String)
    case invalidGiftQuantity(maximum: Int)
    case missingGiftRecipientEmail
    case invalidGiftRecipientEmail
    case giftTimedOut(timeoutSeconds: Int)
    case partialGift(completedCount: Int, requestedCount: Int, message: String)
    case notOwnedUpgradeItem
    case noEligibleUpgradeTargets
    case invalidUpgradeTarget
    case upgradeTargetLookupFailed(message: String)
    case upgradeTimedOut(timeoutSeconds: Int)
    case upgradeRejected(message: String)

    var errorDescription: String? {
        switch self {
        case .actionInProgress:
            return "Hangar Express is already refreshing or finishing another account action."
        case .missingSession:
            return "No signed-in RSI session is currently available for this account action."
        case .missingStoredPassword:
            return "This RSI account no longer has a saved password. Sign in again before Hangar Express can send melt or gift requests."
        case let .invalidMeltQuantity(maximum):
            return "Choose a melt quantity between 1 and \(maximum)."
        case let .meltTimedOut(timeoutSeconds):
            return "RSI did not confirm the melt within \(timeoutSeconds) seconds. Refresh your hangar and hangar log to verify whether the pledge was reclaimed before trying again."
        case let .partialMelt(completedCount, requestedCount, message):
            return "Hangar Express melted \(completedCount) of \(requestedCount) item(s) before RSI stopped the reclaim sequence. Your hangar was refreshed so the remaining inventory stays accurate.\n\n\(message)"
        case let .invalidGiftQuantity(maximum):
            return "Choose a gift quantity between 1 and \(maximum)."
        case .missingGiftRecipientEmail:
            return "Enter the recipient email address before Hangar Express can send the gift."
        case .invalidGiftRecipientEmail:
            return "Enter a valid recipient email address before Hangar Express can send the gift."
        case let .giftTimedOut(timeoutSeconds):
            return "RSI did not confirm the gift within \(timeoutSeconds) seconds. Refresh your hangar and hangar log to verify whether the pledge was gifted before trying again."
        case let .partialGift(completedCount, requestedCount, message):
            return "Hangar Express gifted \(completedCount) of \(requestedCount) item(s) before RSI stopped the gifting sequence. Your hangar was refreshed so the remaining inventory stays accurate.\n\n\(message)"
        case .notOwnedUpgradeItem:
            return "This pledge is not an owned RSI upgrade item, so Hangar Express cannot apply it."
        case .noEligibleUpgradeTargets:
            return "RSI did not return any eligible pledges for this upgrade item."
        case .invalidUpgradeTarget:
            return "Choose a valid target pledge before Hangar Express can apply the upgrade."
        case let .upgradeTargetLookupFailed(message):
            return "Hangar Express could not load the eligible upgrade targets yet.\n\n\(message)"
        case let .upgradeTimedOut(timeoutSeconds):
            return "RSI did not confirm the upgrade within \(timeoutSeconds) seconds. Refresh your hangar and hangar log to verify whether the upgrade was applied before trying again."
        case let .upgradeRejected(message):
            return "RSI did not accept the upgrade request.\n\n\(message)"
        }
    }
}
