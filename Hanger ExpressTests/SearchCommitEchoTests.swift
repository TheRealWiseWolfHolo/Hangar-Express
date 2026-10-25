import Testing
@testable import Hanger_Express

struct SearchCommitEchoTests {
    @Test func delayedLocalEchoDoesNotOverwriteNewerTyping() {
        var tracker = SearchCommitEchoTracker()
        tracker.record("ship ")
        var draft = "ship 1"
        if !tracker.consume("ship ") { draft = "ship " }
        #expect(draft == "ship 1")
    }

    @Test func coalescedEchoAcknowledgesAllEarlierCommits() {
        var tracker = SearchCommitEchoTracker()
        tracker.record("s")
        tracker.record("sh")
        tracker.record("ship")
        let consumed1 = tracker.consume("ship")
        #expect(consumed1)
        let consumed2 = tracker.consume("sh")
        #expect(!consumed2)
    }

    @Test func externalResetRemainsEffectiveAndClearsOldEchoes() {
        var tracker = SearchCommitEchoTracker()
        tracker.record("ship")
        let consumed3 = tracker.consume("")
        #expect(!consumed3)
        let consumed4 = tracker.consume("ship")
        #expect(!consumed4)
    }

    @Test func acknowledgedOrDismissedEchoCannotMaskALaterExternalChange() {
        var tracker = SearchCommitEchoTracker()
        tracker.record("ship")
        let consumed5 = tracker.consume("ship")
        #expect(consumed5)
        let consumed6 = tracker.consume("ship")
        #expect(!consumed6)
        tracker.record("fleet")
        tracker.reset()
        let consumed7 = tracker.consume("fleet")
        #expect(!consumed7)
    }
}
