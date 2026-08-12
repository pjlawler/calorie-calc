import XCTest

/// Walks the first-run flow end to end. This is the app's activation funnel — if it breaks, new
/// users land on a blank week calendar with a silent default plan and never meet the AI, which is
/// exactly the failure this flow was built to fix.
///
/// Requires a genuinely fresh install: `OnboardingGate` deliberately refuses to run for anyone
/// with an existing profile or food log. `xcrun simctl uninstall <device> com.lawlerinnovationsinc-calorie`
/// before running locally.
final class OnboardingUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testWalksFromGoalToFirstLogStep() {
        let app = XCUIApplication()
        app.launch()

        // Step 1 — goal
        XCTAssertTrue(
            app.staticTexts["What's your goal?"].waitForExistence(timeout: 15),
            "First-run flow didn't open on a fresh install"
        )
        let cont = app.buttons["Continue"]
        XCTAssertFalse(cont.isEnabled, "Continue should stay disabled until a goal is picked")
        app.staticTexts["Lose at a moderate pace"].tap()
        XCTAssertTrue(cont.isEnabled)
        attach(app, name: "01-goal")
        cont.tap()

        // Step 2 — about you
        let seePlan = app.buttons["See my plan"]
        XCTAssertTrue(seePlan.waitForExistence(timeout: 5))
        XCTAssertFalse(seePlan.isEnabled, "Shouldn't be able to continue without a sex selection")

        // A Form picker's label carries its current value ("Sex, Select"), so match on the prefix.
        sexPicker(app).tap()
        app.buttons["Female"].tap()
        // Wait for the pushed picker to pop and the row to show the new value before tapping on,
        // otherwise the tap can land mid-animation and go nowhere.
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sex, Female"))
                .firstMatch.waitForExistence(timeout: 5),
            "Sex selection didn't stick"
        )
        attach(app, name: "02-profile")
        let seePlanAgain = app.buttons["See my plan"]
        XCTAssertTrue(seePlanAgain.waitForExistence(timeout: 5))
        XCTAssertTrue(seePlanAgain.isEnabled)
        seePlanAgain.tap()

        // Step 3 — the plan, computed on-device with no network call
        XCTAssertTrue(
            app.staticTexts["Here's your plan"].waitForExistence(timeout: 10),
            "Plan step never appeared. On screen:\n\(app.debugDescription)"
        )
        // LabeledContent merges its label and value into one element ("Daily net, 1,636 kcal"),
        // so match on the prefix rather than an exact string.
        XCTAssertTrue(
            labelled(app, beginningWith: "Daily net").exists,
            "Plan card didn't show a net target"
        )
        XCTAssertTrue(labelled(app, beginningWith: "Daily eating goal").exists)
        XCTAssertTrue(labelled(app, beginningWith: "Refine with AI").exists)
        attach(app, name: "03-plan")
        app.buttons["Start logging"].tap()

        // Step 4 — the activation moment
        XCTAssertTrue(app.staticTexts["Log your first meal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Take a photo of your food"].exists)
        attach(app, name: "04-first-log")

        // Skipping still finishes the flow and lands the user in the app proper.
        app.buttons["I'll log something later"].tap()
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 5),
            "Finishing onboarding should reveal the tab bar"
        )
        attach(app, name: "05-app")
    }

    /// Matches any element whose accessibility label starts with `prefix`, regardless of the
    /// element type SwiftUI happened to synthesise.
    private func labelled(_ app: XCUIApplication, beginningWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
    }

    private func sexPicker(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sex")).firstMatch
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
