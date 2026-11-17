import XCTest
import Foundation
import LocalAuthentication
import CoreLocation
import EventKit
import Contacts
import StoreKit
import CloudKit
import WidgetKit

final class LocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    var failed: XCTestExpectation?
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if case CLError.denied = error { failed?.fulfill() }
    }
}

/// Unavailable services answer through their own denial paths.
final class AuthorizationTests: XCTestCase {
    func testLocalAuthentication() {
        let ctx = LAContext()
        var error: NSError?
        XCTAssertFalse(ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error))
        XCTAssertEqual(error?.code, LAError.Code.biometryNotAvailable.rawValue)
        XCTAssertEqual(error?.domain, LAErrorDomain)
        XCTAssertEqual(ctx.biometryType, .none)
        let replied = expectation(description: "reply")
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock") { ok, err in
            XCTAssertFalse(ok)
            XCTAssertEqual((err as? LAError)?.code, .passcodeNotSet)
            replied.fulfill()
        }
        wait(for: [replied], timeout: 2)
    }

    func testLocationDenied() {
        XCTAssertEqual(CLLocationManager().authorizationStatus, .denied)
        let m = CLLocationManager()
        let d = LocationDelegate()
        d.failed = expectation(description: "denied")
        m.delegate = d
        m.requestLocation()
        wait(for: [d.failed!], timeout: 2)
        let a = CLLocation(latitude: 51.5007, longitude: -0.1246), b = CLLocation(latitude: 48.8584, longitude: 2.2945)
        XCTAssertEqual(a.distance(from: b) / 1000, 340, accuracy: 5)
    }

    func testEventsAndContactsDenied() throws {
        XCTAssertEqual(EKEventStore.authorizationStatus(for: .event), .denied)
        let store = EKEventStore()
        XCTAssertThrowsError(try store.save(EKEvent(eventStore: store), span: .thisEvent))
        XCTAssertEqual(CNContactStore.authorizationStatus(for: .contacts), .denied)
        XCTAssertThrowsError(try CNContactStore().unifiedContacts(matching: NSPredicate(value: true), keysToFetch: [CNContactGivenNameKey as NSString]))
        let c = CNMutableContact()
        c.givenName = "Ada"; c.familyName = "Lovelace"
        XCTAssertEqual(CNContactFormatter.string(from: c, style: .fullName), "Ada Lovelace")
    }

    func testStoreAndCloudUnavailable() async throws {
        let products = try await Product.products(for: ["pro"])
        XCTAssertTrue(products.isEmpty)
        XCTAssertFalse(AppStore.canMakePayments)
        var count = 0
        for await _ in Transaction.currentEntitlements { count += 1 }
        XCTAssertEqual(count, 0)
        let status = try await CKContainer.default().accountStatus()
        XCTAssertEqual(status, .noAccount)
        do {
            _ = try await CKContainer.default().privateCloudDatabase.save(CKRecord(recordType: "Note"))
            XCTFail("expected notAuthenticated")
        } catch CKError.notAuthenticated {}
        let r = CKRecord(recordType: "Note")
        r["title"] = "Hello"
        XCTAssertEqual(r["title"] as? String, "Hello")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
