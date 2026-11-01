import XCTest
@testable import DerpCore

final class FollowUpTests: XCTestCase {
    func testQuestionsMatchTheWebOrderAndRotation() {
        for r in 0..<10 {
            let dumb = FollowUpQuestion.pick(score: 100, rotation: r)
            XCTAssertEqual(dumb.count, 3)
            XCTAssertEqual(dumb.first, .vsUsual)
            XCTAssertFalse(dumb.contains(.wentWell))
            XCTAssertEqual(Set(dumb).count, 3)
        }
        let smart = Set((0..<5).flatMap { FollowUpQuestion.pick(score: 0, rotation: $0) })
        XCTAssertTrue(smart.contains(.wentWell) && smart.contains(.frequency))
        // Same rotation as src/lib/vote-details.ts followUpQuestions.
        XCTAssertEqual(FollowUpQuestion.pick(score: 0, rotation: 1), [.vsUsual, .session, .wentWell])
        XCTAssertEqual(FollowUpQuestion.pick(score: 50, rotation: -1), [.vsUsual, .frequency, .task])
    }

    func testDetailsBodyEncodesOneAnswerAndRefusesJunk() throws {
        let key = "00000000-0000-4000-8000-000000000001"
        let single = try XCTUnwrap(DetailsBody(agent: "codex", key: key, question: .task, values: ["docs"]))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(single)) as? [String: Any]
        XCTAssertEqual(json?["source"] as? String, "menu-bar")
        XCTAssertEqual(json?["idempotencyKey"] as? String, key)
        XCTAssertEqual(json?["agent"] as? String, "codex")
        XCTAssertEqual((json?["answers"] as? [String: Any])?["task"] as? String, "docs")
        let multi = try XCTUnwrap(DetailsBody(agent: "codex", key: key, question: .languages, values: ["go", "go", "cobol", "rust"]))
        XCTAssertEqual(multi.answers, ["languages": .many(["go", "rust"])])
        XCTAssertNil(DetailsBody(agent: "codex", key: key, question: .task, values: ["vibes"]))
        XCTAssertNil(DetailsBody(agent: "codex", key: key, question: .task, values: ["docs", "test"]))
        XCTAssertNil(DetailsBody(agent: "codex", key: key, question: .languages, values: []))
    }

    func testRoundAdvancesAndFinishes() {
        var round = FollowUpRound(agent: .codex, key: "k", score: 100, rotation: 0, at: Date())
        XCTAssertEqual(round.current, .vsUsual)
        round.picked = ["go"]
        round.advance()
        XCTAssertEqual(round.picked, [])
        round.advance(); round.advance()
        XCTAssertTrue(round.finished)
    }

    func testHiddenTitleShowsNoScore() {
        XCTAssertEqual(menuBarTitle(snapshot: nil, agent: .codex, hidden: true), "(·_·) · Derp ?")
        XCTAssertEqual(menuBarTitle(snapshot: nil, agent: .codex), "(·_·) · Derp —")
    }

    func testEveryChoiceHasLabelsInBothLanguages() {
        for language in [Language.en, .ko] {
            let t = L10n(language)
            for q in FollowUpQuestion.allCases {
                XCTAssertFalse(t.question(q).isEmpty)
                for value in q.choices {
                    let label = t.choice(value)
                    XCTAssertFalse(label.isEmpty)
                    XCTAssertNotEqual(label, value, "\(value) needs a label")
                }
            }
        }
    }
}
