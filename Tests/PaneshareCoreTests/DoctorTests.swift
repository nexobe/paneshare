import XCTest
@testable import PaneshareCore

final class DoctorTests: XCTestCase {
    private var healthy: DoctorFacts {
        var f = DoctorFacts()
        f.version = "1.2"; f.build = "3"; f.systemVersion = "27.2"
        f.inApplications = true; f.screenRecording = true; f.accessibility = true
        f.localNetworkAddress = true; f.updatesConfigured = true
        return f
    }

    func testHealthyMacHasNoProblem() {
        XCTAssertFalse(Doctor.hasProblem(healthy))
        XCTAssertTrue(Doctor.text(healthy).hasPrefix("paneshare 1.2 (3), macOS 27.2\n"))
    }

    func testEachProblemIsReportedWithAFix() {
        let breaks: [(inout DoctorFacts) -> Void] = [
            { $0.screenRecording = false }, { $0.accessibility = false }, { $0.quarantined = true },
            { $0.localNetworkAddress = false }, { $0.loginItemNeedsApproval = true },
        ]
        for change in breaks {
            var f = healthy
            change(&f)
            let problems = Doctor.checks(f).filter { $0.status == .problem }
            XCTAssertEqual(problems.count, 1)
            XCTAssertNotNil(problems.first?.fix)
        }
    }

    func testCommandLineDoesNotReportTheShellsPermissions() {
        var f = healthy
        f.screenRecording = false; f.accessibility = false; f.fromCommandLine = true
        XCTAssertFalse(Doctor.hasProblem(f))
        XCTAssertTrue(Doctor.text(f).contains("Permissions weren't checked"))
    }

    func testRunningAppFactsAppearOnlyWhenKnown() {
        XCTAssertFalse(Doctor.text(healthy).contains("Sharing:"))
        var f = healthy
        f.sharing = true; f.listenerStatus = "Listening"; f.pairedHosts = 1; f.pairedViewers = 2
        f.connectedHosts = 1; f.connectedViewers = 0
        let text = Doctor.text(f)
        XCTAssertTrue(text.contains("Sharing: on (Listening)"))
        XCTAssertTrue(text.contains("Paired: 1 to view, 2 that can view this Mac"))
        XCTAssertTrue(text.contains("Connected now: 1 to view, 0 viewing this Mac"))
    }

    func testTailscaleRange() {
        for yes in ["100.64.0.1", "100.106.28.60", "100.127.255.255"] { XCTAssertTrue(Doctor.isTailscale(yes), yes) }
        for no in ["100.63.0.1", "100.128.0.1", "192.168.4.253", "100.64.0", "nope"] { XCTAssertFalse(Doctor.isTailscale(no), no) }
    }
}
