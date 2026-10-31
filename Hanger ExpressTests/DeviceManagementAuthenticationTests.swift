import Foundation
import Testing
@testable import Hanger_Express

struct BrowserAuthenticationTests {
    @Test func trustedDeviceVerificationCodesKeepSixDigitsOnly() {
        #expect(AuthorizedDevicesVerification.normalizedCode(" 12a34-5678 ") == "123456")
        #expect(AuthorizedDevicesVerification.normalizedCode("１２３456") == "123456")
    }

    @Test func knownCurrentDeviceRemainsProtectedFromRemoval() {
        let currentDevice = AuthorizedDevice(id: "42", name: "This iPhone", isCurrent: true)
        let otherDevice = AuthorizedDevice(id: "43", name: "Desktop")

        #expect(currentDevice.shouldProtectFromBulkRemoval)
        #expect(!otherDevice.shouldProtectFromBulkRemoval)
    }

    @Test func suppliesHttpOnlyRSICookiesToEveryBrowserRequest() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cookies = [
            makeCookie(name: "Rsi-Token", value: "launcher-token", expiresAt: now.addingTimeInterval(600)),
            makeCookie(name: "_rsi_device", value: "device-token", expiresAt: nil)
        ]

        let arguments = RSIAuthenticatedWebSession.authenticationValues(
            from: cookies,
            now: now
        )

        #expect(arguments.rsiToken == "launcher-token")
        #expect(arguments.rsiDevice == "device-token")
    }

    @Test func ignoresExpiredAndEmptyDeviceAuthenticationCookies() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cookies = [
            makeCookie(name: "Rsi-Token", value: "expired", expiresAt: now.addingTimeInterval(-1)),
            makeCookie(name: "rsi-token", value: "current", expiresAt: now.addingTimeInterval(600)),
            makeCookie(name: "_rsi_device", value: "   ", expiresAt: nil)
        ]

        let arguments = RSIAuthenticatedWebSession.authenticationValues(
            from: cookies,
            now: now
        )

        #expect(arguments.rsiToken == "current")
        #expect(arguments.rsiDevice.isEmpty)
    }

    @Test func hidesHTMLDeviceManagementFailures() {
        let message = RSIAccountPageBrowser.userFacingDeviceManagementFailure(
            "<!DOCTYPE html><html><head><style>body { color: red; }</style></head></html>",
            debugSummary: "httpStatus=500, responsePreview=<!DOCTYPE html>",
            fallback: "Fallback"
        )

        #expect(message == "RSI device management is temporarily unavailable (HTTP 500). Try again later.")
        #expect(!message.localizedCaseInsensitiveContains("doctype"))
        #expect(!message.localizedCaseInsensitiveContains("style"))
    }

    @Test func preservesStructuredDeviceManagementFailures() {
        let message = RSIAccountPageBrowser.userFacingDeviceManagementFailure(
            "Password confirmation required.",
            debugSummary: "httpStatus=403",
            fallback: "Fallback"
        )

        #expect(message == "Password confirmation required.\n\nhttpStatus=403")
    }

    private func makeCookie(
        name: String,
        value: String,
        expiresAt: Date?
    ) -> SessionCookie {
        SessionCookie(
            name: name,
            value: value,
            domain: ".robertsspaceindustries.com",
            path: "/",
            expiresAt: expiresAt,
            isSecure: true,
            isHTTPOnly: true,
            version: 0
        )
    }
}
