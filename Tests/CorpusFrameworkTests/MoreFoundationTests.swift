import XCTest
import Foundation
@testable import RunwayFoundation
import Security
import ServiceManagement

final class MoreFoundationTests: XCTestCase {
    func testDataDetectorFindsLinksAndDates() throws {
        let d = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.date.rawValue)
        let text = "See https://example.com/a?b=1, mail me@example.org or www.swift.org on 2024-05-01."
        let found = d.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        let urls = found.compactMap(\.url).map(\.absoluteString)
        XCTAssertEqual(urls, ["https://example.com/a?b=1", "mailto:me@example.org", "http://www.swift.org"])
        XCTAssertEqual(found.compactMap(\.date).count, 1)
        XCTAssertEqual(found.first?.resultType, .link)
    }

    func testSysctlProcessInfoNotTraced() {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        XCTAssertEqual(sysctl(&mib, 4, &info, &size, nil, 0), 0)
        XCTAssertEqual(info.kp_proc.p_pid, getpid())
        XCTAssertGreaterThan(info.kp_eproc.e_ppid, 0)
    }

    func testMetadataQueryFinishesEmpty() {
        let q = NSMetadataQuery()
        let finished = expectation(forNotification: NSMetadataQuery.didFinishGatheringNotification, object: q)
        q.start()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(q.resultCount, 0)
    }

    func testCodeIsUnsigned() {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf(SecCSFlags(rawValue: kSecCSDefaultFlags), &code), errSecSuccess)
        XCTAssertEqual(SecCodeCheckValidity(code!, [], nil), errSecCSUnsigned)
        var helperError: Unmanaged<NSError>?
        XCTAssertFalse(SMJobBless(kSMDomainSystemLaunchd, "com.example.helper" as CFString, nil, &helperError))
        XCTAssertNotNil(helperError?.takeRetainedValue())
    }
}
