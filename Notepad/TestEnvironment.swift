import Foundation

// MARK: - Test environment detection
//
// The unit tests are app-hosted: `xcodebuild test` launches Notepad itself and
// injects the test bundle into it. That means a test run goes through the real
// launch path — and without a guard it would restore the user's saved windows,
// rewrite `NotepadSession` in their defaults, and let Sparkle fire a background
// update check in the middle of a test.
//
// `XCTestConfigurationFilePath` is set in the process environment by the test
// runner before `main()`, so it is readable from `NotepadApp.init()` — earlier
// than the injected bundle is loaded. The class check is a belt-and-braces
// second signal for contexts that set one but not the other.

enum TestEnvironment {
    /// True when this process was launched to run the unit test bundle.
    static let isRunningUnitTests: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}
