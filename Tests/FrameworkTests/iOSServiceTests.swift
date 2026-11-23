import ActivityKit
import BackgroundTasks
import XCTest

final class iOSServiceTests: XCTestCase {
    private struct Attributes: ActivityAttributes {
        typealias ContentState = Int
    }

    func testLiveActivitiesAreUnavailable() {
        let staleDate = Date(timeIntervalSince1970: 100)
        let content = ActivityContent(state: 42, staleDate: staleDate)
        XCTAssertEqual(content.state, 42)
        XCTAssertEqual(content.staleDate, staleDate)
        XCTAssertFalse(ActivityAuthorizationInfo().areActivitiesEnabled)
        XCTAssertTrue(Activity<Attributes>.activities.isEmpty)
        XCTAssertThrowsError(try Activity.request(attributes: Attributes(), content: content)) { error in
            XCTAssertEqual(error as? ActivityAuthorizationError, .unsupported)
        }
        XCTAssertTrue(Activity<Attributes>.activities.isEmpty)
    }

    func testBackgroundTasksAreUnavailable() async {
        let scheduler = BGTaskScheduler.shared
        let identifier = "org.runway.preview.refresh"
        let accepted = scheduler.register(forTaskWithIdentifier: identifier, using: nil) { _ in
            XCTFail("Unavailable background tasks cannot launch")
        }
        XCTAssertFalse(accepted)

        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date()
        XCTAssertEqual(request.identifier, identifier)
        XCTAssertThrowsError(try scheduler.submit(request)) { error in
            XCTAssertEqual((error as? BGTaskScheduler.Error)?.code, .unavailable)
        }
        scheduler.cancel(taskRequestWithIdentifier: identifier)
        let pending = await scheduler.pendingTaskRequests()
        XCTAssertTrue(pending.isEmpty)
    }
}
