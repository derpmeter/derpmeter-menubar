import Foundation
import XCTest
@testable import DerpCore

final class LocalizationTests: XCTestCase {
    func testSystemFollowsFirstPreferredLanguage() {
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["ko-KR", "en-US"]), .ko)
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["ko"]), .ko)
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["en-US", "ko-KR"]), .en, "only the first language counts")
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["ja-JP"]), .en)
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["kok-IN"]), .en, "Konkani is not Korean")
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: []), .en)
    }

    func testExplicitChoiceWins() {
        XCTAssertEqual(LanguagePreference.en.resolve(preferred: ["ko-KR"]), .en)
        XCTAssertEqual(LanguagePreference.ko.resolve(preferred: ["en-US"]), .ko)
        XCTAssertEqual(LanguagePreference(rawValue: "ko"), .ko, "stored value round-trips")
    }

    func testGlossaryAndInterpolation() {
        let ko = L10n(.ko), en = L10n(.en)
        XCTAssertEqual(Rating.allCases.map(ko.rating), ["똑똑함", "애매함", "멍청함"])
        XCTAssertEqual(Rating.allCases.map(en.rating), Rating.allCases.map(\.label))
        XCTAssertEqual(ko.outcome(.accepted(replayed: false)), "투표 완료. 고마워요!")
        XCTAssertEqual(ko.nextVoteIn(12 * 60), "12분 후 다시 투표 가능")
        XCTAssertEqual(en.nextVoteIn(12 * 60), "Next vote in 12 min")
        XCTAssertEqual(ko.wait(3900), "1시간 5분")
        XCTAssertEqual(ko.wait(20), "1분 미만")
        XCTAssertEqual(ko.derpScore, "멍청 지수")
        XCTAssertEqual(en.smashCaption(SmashMachine()), SmashMachine().caption)
    }

    func testMenuBarTitleIsNotTranslated() {
        // The compact title has no translatable text; it never depends on the language.
        XCTAssertEqual(menuBarTitle(snapshot: nil, agent: .codex), "(·_·) · Derp —")
    }

    @MainActor
    func testSmashFeedbackFollowsLanguage() async {
        final class Voter: SmashVoter {
            func smashNextVoteAt() -> Date? { nil }
            func submitSmashVote(_ rating: Rating) async -> SmashVoteResult { .accepted }
        }
        let voter = Voter()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let c = SmashController(voter: voter, repairDuration: 0) { now }
        c.language = .ko
        for _ in 0..<SmashMachine.promptAt { c.hit(); now = now.addingTimeInterval(1) }
        await c.vote(.dumb)
        XCTAssertEqual(c.feedback, "투표 완료: 멍청함. 수리 중…")
    }
}
