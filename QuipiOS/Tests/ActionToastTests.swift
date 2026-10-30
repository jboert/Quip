import XCTest
@testable import Quip

@MainActor
final class ActionToastTests: XCTestCase {
    private var timers: [(delay: TimeInterval, fire: () -> Void)] = []

    private func makeModel() -> ActionToastModel {
        ActionToastModel(schedule: { [unowned self] delay, fire in self.timers.append((delay, fire)) })
    }

    func test_dismissesAfterFourSeconds() {
        let model = makeModel()
        model.show("Order: Manual", actionTitle: "Use Recent") {}
        XCTAssertEqual(model.current?.text, "Order: Manual")
        XCTAssertEqual(timers.map(\.delay), [4])
        timers[0].fire()
        XCTAssertNil(model.current)
    }

    func test_anOlderTimer_leavesANewerToastUp() {
        let model = makeModel()
        model.show("first", actionTitle: "A") {}
        model.show("second", actionTitle: "B") {}
        timers[0].fire()
        XCTAssertEqual(model.current?.text, "second")
        timers[1].fire()
        XCTAssertNil(model.current)
    }

    func test_action_runsOnceAndDismisses() {
        let model = makeModel()
        var runs = 0
        model.show("Order: Manual", actionTitle: "Use Recent") { runs += 1 }
        model.performAction()
        model.performAction()
        XCTAssertEqual(runs, 1)
        XCTAssertNil(model.current)
    }

    func test_replacedToast_runsOnlyTheNewAction() {
        let model = makeModel()
        var ran: [String] = []
        model.show("first", actionTitle: "A") { ran.append("A") }
        model.show("second", actionTitle: "B") { ran.append("B") }
        model.performAction()
        XCTAssertEqual(ran, ["B"])
    }

    func test_voiceOverReadsTheTextAndTheAction() {
        let model = makeModel()
        model.show("Order: Manual", actionTitle: "Use Recent") {}
        XCTAssertEqual(ActionToastView.accessibilityLabel(model.current!), "Order: Manual, Use Recent")
    }
}
