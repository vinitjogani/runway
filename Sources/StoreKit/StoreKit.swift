// StoreKit for Linux and Windows: there's no App Store, so products are
// never found (Product.products(for:) returns [], SKProductsRequest reports
// every identifier invalid), purchases can't be made (canMakePayments is
// false), entitlements and updates are empty, and review requests are
// no-ops. Apps show their "store unavailable" state.

@_exported import Foundation

public enum StoreKitError: Error, Equatable, Sendable, LocalizedError {
    case unknown
    case userCancelled
    case networkError(URLError)
    case systemError(String)
    case notAvailableInStorefront
    case notEntitled
    case unsupported
    public var errorDescription: String? { "The App Store isn't available on this platform." }
    public static func == (a: StoreKitError, b: StoreKitError) -> Bool { String(describing: a) == String(describing: b) }
}

public enum VerificationResult<SignedType: Sendable>: Sendable {
    case unverified(SignedType, VerificationError)
    case verified(SignedType)
    public enum VerificationError: Error, Sendable { case revokedCertificate, invalidCertificateChain, invalidDeviceVerification, invalidEncoding, invalidSignature, missingRequiredProperties }
    public var unsafePayloadValue: SignedType { switch self { case .verified(let v), .unverified(let v, _): return v } }
    public var payloadValue: SignedType { get throws { switch self { case .verified(let v): return v; case .unverified(_, let e): throw e } } }
    public var jwsRepresentation: String { "" }
}

public struct Product: Identifiable, Hashable, Sendable {
    public struct ProductType: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let consumable = ProductType(rawValue: "consumable")
        public static let nonConsumable = ProductType(rawValue: "nonConsumable")
        public static let autoRenewable = ProductType(rawValue: "autoRenewable")
        public static let nonRenewable = ProductType(rawValue: "nonRenewable")
    }
    public struct SubscriptionPeriod: Hashable, Sendable {
        public enum Unit: Hashable, Sendable { case day, week, month, year }
        public let unit: Unit
        public let value: Int
    }
    public struct SubscriptionOffer: Hashable, Sendable {
        public enum PaymentMode: Hashable, Sendable { case payAsYouGo, payUpFront, freeTrial }
        public let id: String?
        public let displayPrice: String
        public let price: Decimal
        public let period: SubscriptionPeriod
        public let periodCount: Int
        public let paymentMode: PaymentMode
    }
    public struct SubscriptionInfo: Hashable, Sendable {
        public let subscriptionGroupID: String
        public let subscriptionPeriod: SubscriptionPeriod
        public let introductoryOffer: SubscriptionOffer?
        public let promotionalOffers: [SubscriptionOffer]
        public var isEligibleForIntroOffer: Bool { get async { false } }
        public static func isEligibleForIntroOffer(for groupID: String) async -> Bool { false }
        public struct Status: Sendable {
            public enum RenewalState: Hashable, Sendable { case subscribed, expired, inBillingRetryPeriod, inGracePeriod, revoked }
            public let state: RenewalState
            public let transaction: VerificationResult<Transaction>
        }
        public var status: [Status] { get async throws { [] } }
        public static func status(for groupID: String) async throws -> [Status] { [] }
    }
    public enum PurchaseOption: Hashable, Sendable {
        case appAccountToken(UUID)
        case quantity(Int)
        case simulatesAskToBuyInSandbox(Bool)
    }
    public enum PurchaseResult: Sendable {
        case success(VerificationResult<Transaction>)
        case userCancelled
        case pending
    }
    public enum PurchaseError: Error, Sendable { case invalidQuantity, productUnavailable, purchaseNotAllowed, ineligibleForOffer, invalidOfferIdentifier, invalidOfferPrice, invalidOfferSignature, missingOfferParameters }

    public let id: String
    public let type: ProductType
    public let displayName: String
    public let description: String
    public let price: Decimal
    public let displayPrice: String
    public let isFamilyShareable: Bool
    public let subscription: SubscriptionInfo?
    public var priceFormatStyle: Decimal.FormatStyle.Currency { .init(code: "USD") }

    public static func products<C: Collection>(for identifiers: C) async throws -> [Product] where C.Element == String { [] }
    public func purchase(options: Set<PurchaseOption> = []) async throws -> PurchaseResult { throw PurchaseError.productUnavailable }
    public var currentEntitlement: VerificationResult<Transaction>? { get async { nil } }
}

public struct Transaction: Identifiable, Hashable, Sendable {
    public enum OwnershipType: Hashable, Sendable { case purchased, familyShared }
    public struct RevocationReason: Hashable, Sendable { public static let developerIssue = RevocationReason(); public static let other = RevocationReason() }
    public let id: UInt64
    public let originalID: UInt64
    public let productID: String
    public let productType: Product.ProductType
    public let purchaseDate: Date
    public let originalPurchaseDate: Date
    public let expirationDate: Date?
    public let revocationDate: Date?
    public let revocationReason: RevocationReason?
    public let isUpgraded: Bool
    public let ownershipType: OwnershipType
    public let purchasedQuantity: Int
    public let appAccountToken: UUID?
    public func finish() async {}

    public static var currentEntitlements: Transactions { Transactions() }
    public static var all: Transactions { Transactions() }
    public static var unfinished: Transactions { Transactions() }
    public static var updates: Transactions { Transactions() }
    public static func currentEntitlement(for productID: String) async -> VerificationResult<Transaction>? { nil }
    public static func latest(for productID: String) async -> VerificationResult<Transaction>? { nil }

    /// Always empty: there are no purchases.
    public struct Transactions: AsyncSequence, Sendable {
        public typealias Element = VerificationResult<Transaction>
        public struct AsyncIterator: AsyncIteratorProtocol {
            public mutating func next() async -> VerificationResult<Transaction>? { nil }
        }
        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
    }
}

public struct AppTransaction: Sendable {
    public static var shared: VerificationResult<AppTransaction> { get async throws { throw StoreKitError.unsupported } }
    public static func refresh() async throws -> VerificationResult<AppTransaction> { throw StoreKitError.unsupported }
    public let appVersion: String
    public let originalAppVersion: String
    public let originalPurchaseDate: Date
}

public enum AppStore {
    public static var canMakePayments: Bool { false }
    public static func sync() async throws { throw StoreKitError.unsupported }
    public static func showManageSubscriptions(in scene: AnyObject) async throws { throw StoreKitError.unsupported }
    public static func requestReview(in scene: AnyObject) {}
}

public struct Storefront: Sendable {
    public let countryCode: String
    public let id: String
    public static var current: Storefront? { get async { nil } }
}

// MARK: StoreKit 1

open class SKStoreReviewController: NSObject {
    open class func requestReview() {}
    open class func requestReview(in windowScene: AnyObject) {}
}

open class SKProduct: NSObject, @unchecked Sendable {
    open var localizedDescription: String { "" }
    open var localizedTitle: String { "" }
    open var price: NSDecimalNumber { .zero }
    open var priceLocale: Locale { .current }
    open var productIdentifier: String { "" }
}

open class SKProductsResponse: NSObject, @unchecked Sendable {
    open private(set) var products: [SKProduct] = []
    open private(set) var invalidProductIdentifiers: [String]
    init(invalid: [String]) { invalidProductIdentifiers = invalid }
}

public protocol SKRequestDelegate: NSObjectProtocol {
    func requestDidFinish(_ request: SKRequest)
    func request(_ request: SKRequest, didFailWithError error: Error)
}
extension SKRequestDelegate {
    public func requestDidFinish(_ request: SKRequest) {}
    public func request(_ request: SKRequest, didFailWithError error: Error) {}
}
public protocol SKProductsRequestDelegate: SKRequestDelegate {
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse)
}

open class SKRequest: NSObject, @unchecked Sendable {
    open func start() {}
    open func cancel() {}
}

open class SKProductsRequest: SKRequest, @unchecked Sendable {
    let identifiers: Set<String>
    open weak var delegate: SKProductsRequestDelegate?
    public init(productIdentifiers: Set<String>) { identifiers = productIdentifiers }
    open override func start() {
        DispatchQueue.main.async { [self] in
            delegate?.productsRequest(self, didReceive: SKProductsResponse(invalid: Array(identifiers)))
            delegate?.requestDidFinish(self)
        }
    }
}

open class SKPaymentQueue: NSObject, @unchecked Sendable {
    open class func `default`() -> SKPaymentQueue { shared }
    private static let shared = SKPaymentQueue()
    open class func canMakePayments() -> Bool { false }
    open func add(_ observer: AnyObject) {}
    open func remove(_ observer: AnyObject) {}
    open func restoreCompletedTransactions() {}
}
