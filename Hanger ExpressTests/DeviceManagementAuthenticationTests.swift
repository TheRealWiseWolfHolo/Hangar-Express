import Foundation
import Testing
@testable import Hanger_Express

struct DeviceManagementAuthenticationTests {
    @Test func suppliesHttpOnlyRSICookiesToDeviceRequests() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cookies = [
            makeCookie(name: "Rsi-Token", value: "launcher-token", expiresAt: now.addingTimeInterval(600)),
            makeCookie(name: "_rsi_device", value: "device-token", expiresAt: nil)
        ]

        let arguments = RSIAccountPageBrowser.deviceManagementAuthenticationArguments(
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

        let arguments = RSIAccountPageBrowser.deviceManagementAuthenticationArguments(
            from: cookies,
            now: now
        )

        #expect(arguments.rsiToken == "current")
        #expect(arguments.rsiDevice.isEmpty)
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
