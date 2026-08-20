import XCTest
@testable import AfterRayApp

@MainActor
final class AfterRayTerminationStateTests: XCTestCase {
    func testRepeatedQuitStartsExactlyOneCleanupTask() async {
        let state = AfterRayTerminationState()
        var synchronousStarts = 0
        var exportCleanups = 0
        var daemonCleanups = 0

        let first = state.begin(onStart: {
            synchronousStarts += 1
        }) {
            await performAfterRayTerminationCleanup(
                exportCleanup: {
                    exportCleanups += 1
                    await Task.yield()
                },
                daemonCleanup: {
                    daemonCleanups += 1
                    await Task.yield()
                }
            )
        }
        let second = state.begin(onStart: {
            synchronousStarts += 1
        }) {
            XCTFail("a repeated Quit must not start another cleanup")
        }

        await state.waitForCleanup()
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertTrue(state.isTerminating)
        XCTAssertEqual(synchronousStarts, 1)
        XCTAssertEqual(exportCleanups, 1)
        XCTAssertEqual(daemonCleanups, 1)
    }
}
