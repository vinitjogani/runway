// CoreLocation for Linux and Windows: location services answer as on a Mac
// where the user denied the app: authorizationStatus is .denied, requests
// call locationManager(_:didFailWithError:) with CLError(.denied), and the
// delegate hears the status on locationManagerDidChangeAuthorization.
// Geocoding fails with CLError(.network). Types and math are real.

@_exported import Foundation

public typealias CLLocationDegrees = Double
public typealias CLLocationDistance = Double
public typealias CLLocationAccuracy = Double
public typealias CLLocationSpeed = Double
public typealias CLLocationSpeedAccuracy = Double
public typealias CLLocationDirection = Double
public typealias CLLocationDirectionAccuracy = Double
public typealias CLHeadingComponentValue = Double

public let kCLLocationAccuracyBestForNavigation: CLLocationAccuracy = -2
public let kCLLocationAccuracyBest: CLLocationAccuracy = -1
public let kCLLocationAccuracyNearestTenMeters: CLLocationAccuracy = 10
public let kCLLocationAccuracyHundredMeters: CLLocationAccuracy = 100
public let kCLLocationAccuracyKilometer: CLLocationAccuracy = 1000
public let kCLLocationAccuracyThreeKilometers: CLLocationAccuracy = 3000
public let kCLLocationAccuracyReduced: CLLocationAccuracy = 3000
public let kCLDistanceFilterNone: CLLocationDistance = -1
public let CLLocationDistanceMax: CLLocationDistance = .greatestFiniteMagnitude
public let kCLErrorDomain = "kCLErrorDomain"

public struct CLLocationCoordinate2D: Sendable, Equatable {
    public var latitude: CLLocationDegrees
    public var longitude: CLLocationDegrees
    public init() { latitude = 0; longitude = 0 }
    public init(latitude: CLLocationDegrees, longitude: CLLocationDegrees) { self.latitude = latitude; self.longitude = longitude }
}
public let kCLLocationCoordinate2DInvalid = CLLocationCoordinate2D(latitude: -180, longitude: -180)
public func CLLocationCoordinate2DIsValid(_ c: CLLocationCoordinate2D) -> Bool { abs(c.latitude) <= 90 && abs(c.longitude) <= 180 }
public func CLLocationCoordinate2DMake(_ latitude: CLLocationDegrees, _ longitude: CLLocationDegrees) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
}

public enum CLAuthorizationStatus: Int32, Sendable {
    case notDetermined = 0, restricted, denied, authorizedAlways, authorizedWhenInUse
    public static var authorized: CLAuthorizationStatus { .authorizedAlways }
}
public enum CLAccuracyAuthorization: Int, Sendable { case fullAccuracy = 0, reducedAccuracy }
public enum CLActivityType: Int, Sendable { case other = 1, automotiveNavigation, fitness, otherNavigation, airborne }

public struct CLError: CustomNSError, Hashable, Error, Sendable {
    public enum Code: Int, Sendable {
        case locationUnknown = 0, denied, network, headingFailure, regionMonitoringDenied, regionMonitoringFailure
        case regionMonitoringSetupDelayed, regionMonitoringResponseDelayed, geocodeFoundNoResult, geocodeFoundPartialResult
        case geocodeCanceled, deferredFailed, deferredNotUpdatingLocation, deferredAccuracyTooLow, deferredDistanceFiltered
        case deferredCanceled, rangingUnavailable, rangingFailure, promptDeclined, historicalLocationError
    }
    public let code: Code
    public init(_ code: Code) { self.code = code }
    public static var errorDomain: String { kCLErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] { [:] }
    public static var denied: Code { .denied }
    public static var locationUnknown: Code { .locationUnknown }
    public static var network: Code { .network }
}

public func ~= (code: CLError.Code, error: Error) -> Bool { (error as? CLError)?.code == code }

open class CLLocation: NSObject, @unchecked Sendable {
    public let coordinate: CLLocationCoordinate2D
    public let altitude: CLLocationDistance
    public let horizontalAccuracy: CLLocationAccuracy
    public let verticalAccuracy: CLLocationAccuracy
    public let course: CLLocationDirection
    public let courseAccuracy: CLLocationDirectionAccuracy
    public let speed: CLLocationSpeed
    public let speedAccuracy: CLLocationSpeedAccuracy
    public let timestamp: Date
    public var ellipsoidalAltitude: CLLocationDistance { altitude }

    public convenience init(latitude: CLLocationDegrees, longitude: CLLocationDegrees) {
        self.init(coordinate: .init(latitude: latitude, longitude: longitude), altitude: 0, horizontalAccuracy: 0, verticalAccuracy: -1, timestamp: Date())
    }
    public init(coordinate: CLLocationCoordinate2D, altitude: CLLocationDistance, horizontalAccuracy: CLLocationAccuracy,
                verticalAccuracy: CLLocationAccuracy, timestamp: Date) {
        self.coordinate = coordinate; self.altitude = altitude; self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy; self.timestamp = timestamp
        course = -1; courseAccuracy = -1; speed = -1; speedAccuracy = -1
    }
    public init(coordinate: CLLocationCoordinate2D, altitude: CLLocationDistance, horizontalAccuracy: CLLocationAccuracy,
                verticalAccuracy: CLLocationAccuracy, course: CLLocationDirection, speed: CLLocationSpeed, timestamp: Date) {
        self.coordinate = coordinate; self.altitude = altitude; self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy; self.timestamp = timestamp
        self.course = course; courseAccuracy = -1; self.speed = speed; speedAccuracy = -1
    }

    /// Great-circle distance (haversine, mean Earth radius).
    open func distance(from location: CLLocation) -> CLLocationDistance {
        let r = 6_371_008.8
        let (la1, la2) = (coordinate.latitude * .pi / 180, location.coordinate.latitude * .pi / 180)
        let dLat = la2 - la1
        let dLon = (location.coordinate.longitude - coordinate.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

open class CLRegion: NSObject, @unchecked Sendable {
    public let identifier: String
    open var notifyOnEntry = true
    open var notifyOnExit = true
    public init(identifier: String) { self.identifier = identifier }
}
open class CLCircularRegion: CLRegion, @unchecked Sendable {
    public let center: CLLocationCoordinate2D
    public let radius: CLLocationDistance
    public init(center: CLLocationCoordinate2D, radius: CLLocationDistance, identifier: String) {
        self.center = center; self.radius = radius
        super.init(identifier: identifier)
    }
    open func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: center.latitude, longitude: center.longitude).distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) <= radius
    }
}

open class CLHeading: NSObject, @unchecked Sendable {
    open var magneticHeading: CLLocationDirection { -1 }
    open var trueHeading: CLLocationDirection { -1 }
    open var headingAccuracy: CLLocationDirection { -1 }
    open var timestamp: Date { Date() }
}

public protocol CLLocationManagerDelegate: NSObjectProtocol {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation])
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error)
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager)
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading)
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion)
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion)
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error)
}

extension CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {}
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {}
    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {}
    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {}
    public func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {}
}

open class CLLocationManager: NSObject, @unchecked Sendable {
    open weak var delegate: CLLocationManagerDelegate? {
        didSet { if delegate != nil { announceAuthorization() } }
    }
    open var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    open var distanceFilter: CLLocationDistance = kCLDistanceFilterNone
    open var activityType: CLActivityType = .other
    open var pausesLocationUpdatesAutomatically = true
    open var allowsBackgroundLocationUpdates = false
    open var headingFilter: CLLocationDirection = 1
    open var location: CLLocation? { nil }
    open var heading: CLHeading? { nil }
    open var monitoredRegions: Set<CLRegion> { [] }
    open var maximumRegionMonitoringDistance: CLLocationDistance { -1 }
    open var authorizationStatus: CLAuthorizationStatus { .denied }
    open var accuracyAuthorization: CLAccuracyAuthorization { .reducedAccuracy }
    open var isAuthorizedForWidgetUpdates: Bool { false }

    public override init() { super.init() }

    open class func authorizationStatus() -> CLAuthorizationStatus { .denied }
    open class func locationServicesEnabled() -> Bool { false }
    open class func headingAvailable() -> Bool { false }
    open class func significantLocationChangeMonitoringAvailable() -> Bool { false }
    open class func isMonitoringAvailable(for regionClass: AnyClass) -> Bool { false }
    open class func isRangingAvailable() -> Bool { false }

    private func announceAuthorization() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let d = self.delegate else { return }
            d.locationManagerDidChangeAuthorization(self)
            d.locationManager(self, didChangeAuthorization: .denied)
        }
    }

    private func deny() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.locationManager(self, didFailWithError: CLError(.denied))
        }
    }

    open func requestWhenInUseAuthorization() { announceAuthorization() }
    open func requestAlwaysAuthorization() { announceAuthorization() }
    open func requestTemporaryFullAccuracyAuthorization(withPurposeKey purposeKey: String, completion: (@Sendable (Error?) -> Void)? = nil) {
        DispatchQueue.main.async { completion?(CLError(.denied)) }
    }
    open func requestTemporaryFullAccuracyAuthorization(withPurposeKey purposeKey: String) async throws { throw CLError(.denied) }
    open func startUpdatingLocation() { deny() }
    open func stopUpdatingLocation() {}
    open func requestLocation() { deny() }
    open func startMonitoringSignificantLocationChanges() { deny() }
    open func stopMonitoringSignificantLocationChanges() {}
    open func startUpdatingHeading() {}
    open func stopUpdatingHeading() {}
    open func startMonitoring(for region: CLRegion) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.locationManager(self, monitoringDidFailFor: region, withError: CLError(.regionMonitoringDenied))
        }
    }
    open func stopMonitoring(for region: CLRegion) {}
    open func dismissHeadingCalibrationDisplay() {}
}

open class CLPlacemark: NSObject, @unchecked Sendable {
    open var location: CLLocation? { nil }
    open var name: String? { nil }
    open var thoroughfare: String? { nil }
    open var subThoroughfare: String? { nil }
    open var locality: String? { nil }
    open var subLocality: String? { nil }
    open var administrativeArea: String? { nil }
    open var subAdministrativeArea: String? { nil }
    open var postalCode: String? { nil }
    open var isoCountryCode: String? { nil }
    open var country: String? { nil }
    open var timeZone: TimeZone? { nil }
}

open class CLGeocoder: NSObject, @unchecked Sendable {
    public typealias CompletionHandler = @Sendable ([CLPlacemark]?, Error?) -> Void
    open var isGeocoding: Bool { false }
    public override init() { super.init() }
    open func reverseGeocodeLocation(_ location: CLLocation, completionHandler: @escaping CompletionHandler) {
        DispatchQueue.main.async { completionHandler(nil, CLError(.network)) }
    }
    open func reverseGeocodeLocation(_ location: CLLocation, preferredLocale locale: Locale?, completionHandler: @escaping CompletionHandler) {
        reverseGeocodeLocation(location, completionHandler: completionHandler)
    }
    open func reverseGeocodeLocation(_ location: CLLocation) async throws -> [CLPlacemark] { throw CLError(.network) }
    open func geocodeAddressString(_ addressString: String, completionHandler: @escaping CompletionHandler) {
        DispatchQueue.main.async { completionHandler(nil, CLError(.network)) }
    }
    open func geocodeAddressString(_ addressString: String) async throws -> [CLPlacemark] { throw CLError(.network) }
    open func cancelGeocode() {}
}
