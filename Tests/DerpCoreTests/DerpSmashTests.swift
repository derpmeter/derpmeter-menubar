import CoreGraphics
@testable import DerpCore
import XCTest

final class SmashMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ n: Int) -> Date { t0.addingTimeInterval(Double(n)) }

    func testHitProgressionAndPrompt() {
        var m = SmashMachine()
        XCTAssertEqual(m.state, .idle)
        let expected: [SmashState] = [.lightDamage, .lightDamage, .heavyDamage, .heavyDamage, .voting]
        for (i, state) in expected.enumerated() {
            XCTAssertTrue(m.hit(now: at(i), cooldownUntil: nil))
            XCTAssertEqual(m.state, state, "after \(i + 1) hits")
        }
        XCTAssertEqual(m.hits, 5)
        XCTAssertTrue(m.promptVisible)
        XCTAssertEqual(m.caption, "AI.exe has stopped thinking")
    }

    func testRateLimitIgnoresRapidClicks() {
        var m = SmashMachine()
        XCTAssertTrue(m.hit(now: t0, cooldownUntil: nil))
        XCTAssertFalse(m.hit(now: t0.addingTimeInterval(0.05), cooldownUntil: nil))
        XCTAssertEqual(m.hits, 1)
        XCTAssertTrue(m.hit(now: t0.addingTimeInterval(SmashMachine.minHitInterval + 0.01), cooldownUntil: nil))
        XCTAssertEqual(m.hits, 2)
    }

    func testDismissNeverTrapsAndMoreHitsDoNotReopen() {
        var m = SmashMachine()
        for i in 0..<5 { m.hit(now: at(i), cooldownUntil: nil) }
        m.dismissPrompt()
        XCTAssertEqual(m.state, .broken)
        m.hit(now: at(10), cooldownUntil: nil)
        XCTAssertEqual(m.state, .broken)
        XCTAssertFalse(m.promptVisible)
        XCTAssertEqual(m.caption, "Rate your AI before smashing again?")
        // Reopened only on request.
        m.openPrompt(now: at(11), cooldownUntil: nil)
        XCTAssertEqual(m.state, .voting)
    }

    func testCooldownPromptAndTick() {
        var m = SmashMachine()
        let until = at(600)
        for i in 0..<5 { m.hit(now: at(i), cooldownUntil: until) }
        XCTAssertEqual(m.state, .cooldown)
        XCTAssertEqual(m.cooldownUntil, until)
        m.tick(now: at(100))
        XCTAssertEqual(m.state, .cooldown)
        m.tick(now: until)
        XCTAssertEqual(m.state, .voting)
        // A past cooldown does not block.
        var fresh = SmashMachine()
        for i in 0..<5 { fresh.hit(now: at(i), cooldownUntil: at(-1)) }
        XCTAssertEqual(fresh.state, .voting)
    }

    func testManualRepairResetsEverything() {
        var m = SmashMachine()
        for i in 0..<3 { m.hit(now: at(i), cooldownUntil: nil) }
        m.startRepair()
        XCTAssertEqual(m.state, .repairing)
        XCTAssertFalse(m.hit(now: at(10), cooldownUntil: nil), "no hits while repairing")
        m.finishRepair()
        XCTAssertEqual(m, SmashMachine())
    }
}

@MainActor
final class SmashControllerTests: XCTestCase {
    final class Voter: SmashVoter {
        var next: Date?
        var results: [SmashVoteResult] = []
        var submitted: [Rating] = []
        var gate: CheckedContinuation<Void, Never>?
        var holdNext = false
        func smashNextVoteAt() -> Date? { next }
        func submitSmashVote(_ rating: Rating) async -> SmashVoteResult {
            submitted.append(rating)
            if holdNext { await withCheckedContinuation { gate = $0 } }
            return results.isEmpty ? .accepted : results.removeFirst()
        }
    }

    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(_ voter: Voter) -> SmashController {
        SmashController(voter: voter, repairDuration: 0) { [unowned self] in self.now }
    }

    private func smash(_ c: SmashController, times: Int) {
        for _ in 0..<times {
            c.hit()
            now = now.addingTimeInterval(1)
        }
    }

    func testHitsStayLocalAndNeverVote() {
        let voter = Voter()
        let c = make(voter)
        smash(c, times: 12)
        XCTAssertEqual(voter.submitted, [], "smashing never submits a vote")
        XCTAssertEqual(c.machine.state, .voting)
        XCTAssertEqual(c.impacts, 12)
    }

    func testEachBrokenCRTIsCountedOnce() async {
        let voter = Voter()
        let c = make(voter)
        var broken = 0
        c.onBroken = { broken += 1 }
        smash(c, times: 12)
        XCTAssertEqual(broken, 1, "more hits on a broken CRT are not new breaks")
        c.repair()
        await c.waitForRepair()
        smash(c, times: 5)
        XCTAssertEqual(broken, 2)
    }

    func testVoteSuccessRepairs() async {
        let voter = Voter()
        let c = make(voter)
        smash(c, times: 5)
        await c.vote(.meh)
        XCTAssertEqual(voter.submitted, [.meh])
        XCTAssertEqual(c.machine.state, .repairing)
        await c.waitForRepair()
        XCTAssertEqual(c.machine.state, .idle)
        XCTAssertEqual(c.machine.hits, 0)
    }

    func testVoteFailureKeepsPromptOpen() async {
        let voter = Voter()
        voter.results = [.failed("Token rejected. Check Settings.")]
        let c = make(voter)
        smash(c, times: 5)
        await c.vote(.dumb)
        XCTAssertEqual(c.machine.state, .voting)
        XCTAssertEqual(c.feedback, "Token rejected. Check Settings.")
    }

    func testOfflineQueuedVoteRepairs() async {
        let voter = Voter()
        voter.results = [.queued("Offline: vote queued. It retries automatically.")]
        let c = make(voter)
        smash(c, times: 5)
        await c.vote(.smart)
        XCTAssertEqual(c.feedback, "Offline: vote queued. It retries automatically.")
        await c.waitForRepair()
        XCTAssertEqual(c.machine.state, .idle)
    }

    func testCooldownBlocksSubmission() async {
        let voter = Voter()
        voter.next = now.addingTimeInterval(1800)
        let c = make(voter)
        smash(c, times: 5)
        XCTAssertEqual(c.machine.state, .cooldown)
        await c.vote(.dumb)
        XCTAssertEqual(voter.submitted, [], "no submission during the cooldown")
        // Server says limited: prompt switches to the cooldown view.
        voter.next = nil
        let fresh = make(voter)
        smash(fresh, times: 5)
        voter.results = [.limited(now.addingTimeInterval(600))]
        await fresh.vote(.meh)
        XCTAssertEqual(fresh.machine.state, .cooldown)
        XCTAssertEqual(voter.submitted, [.meh])
    }

    func testNoDuplicateSubmission() async {
        let voter = Voter()
        voter.holdNext = true
        let c = make(voter)
        smash(c, times: 5)
        let first = Task { await c.vote(.meh) }
        while voter.gate == nil { await Task.yield() }
        XCTAssertTrue(c.submitting)
        await c.vote(.meh)
        await c.vote(.dumb)
        XCTAssertEqual(voter.submitted, [.meh], "second and third taps ignored while sending")
        voter.gate?.resume()
        await first.value
        XCTAssertFalse(c.submitting)
    }

    func testManualRepairWithoutVotingAndReset() async {
        let voter = Voter()
        let c = make(voter)
        smash(c, times: 3)
        c.repair()
        await c.waitForRepair()
        XCTAssertEqual(c.machine, SmashMachine())
        smash(c, times: 5)
        c.reset() // disabling the pet
        XCTAssertEqual(c.machine, SmashMachine())
        XCTAssertNil(c.feedback)
        XCTAssertEqual(voter.submitted, [])
    }
}

final class SmashPreferencesTests: XCTestCase {
    func testDefaultsOffAndPersistence() throws {
        let suite = "derpsmash.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SmashPreferencesStore(defaults: defaults)
        XCTAssertFalse(store.load().enabled, "disabled for existing users")
        var prefs = SmashPreferences()
        prefs.enabled = true
        prefs.weapon = .bat
        prefs.muted = true
        prefs.origin = CGPoint(x: 120, y: 80)
        store.save(prefs)
        XCTAssertEqual(SmashPreferencesStore(defaults: defaults).load(), prefs)
    }

    func testOlderSettingsKeepTheirValuesAndDefaultToSmall() throws {
        let old = #"{"enabled":true,"weapon":"bat","muted":true,"keepOnTop":false,"origin":[632,557]}"#
        let prefs = try JSONDecoder().decode(SmashPreferences.self, from: Data(old.utf8))
        XCTAssertTrue(prefs.enabled)
        XCTAssertEqual(prefs.weapon, .bat)
        XCTAssertEqual(prefs.size, .small)
        XCTAssertEqual(prefs.origin, CGPoint(x: 632, y: 557))
        XCTAssertEqual(SmashPreferences().size, .small)
    }

    func testLayoutScalesTheCRTButKeepsThePromptReadable() {
        let small = SmashLayout(size: .small)
        XCTAssertEqual(small.crt, CGSize(width: 132, height: 126))
        XCTAssertEqual(small.promptScale, 0.85)
        XCTAssertEqual(small.window(prompt: false), small.crt)
        XCTAssertEqual(small.window(prompt: true), CGSize(width: 187, height: 126 + 149.6))
        let large = SmashLayout(size: .large)
        XCTAssertEqual(large.window(prompt: true), CGSize(width: 220, height: 386))
    }

    func testPlacementAcrossDisplays() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let side = CGRect(x: 1440, y: -200, width: 1920, height: 1050)
        let size = CGSize(width: 220, height: 210)
        // Saved on the second display: kept there.
        XCTAssertEqual(smashPlacement(saved: CGPoint(x: 2000, y: 100), size: size, screens: [main, side]),
                       CGPoint(x: 2000, y: 100))
        // Hanging off the right edge: clamped fully inside that display.
        XCTAssertEqual(smashPlacement(saved: CGPoint(x: 3300, y: 100), size: size, screens: [main, side]),
                       CGPoint(x: 3360 - 220, y: 100))
        // Display gone: default bottom-right of the main screen.
        XCTAssertEqual(smashPlacement(saved: CGPoint(x: 5000, y: 100), size: size, screens: [main]),
                       CGPoint(x: 1440 - 220 - 24, y: 24))
        XCTAssertEqual(smashPlacement(saved: nil, size: size, screens: [main, side]),
                       CGPoint(x: 1440 - 220 - 24, y: 24))
    }
}
