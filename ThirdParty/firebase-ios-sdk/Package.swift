// swift-tools-version:5.9
// Runway's stand-in for the Firebase Apple SDK (github.com/firebase/firebase-ios-sdk),
// whose analytics and crash reporting ship as Apple-only binaries. Same
// identity and products; `import Firebase` (and each product's module)
// gives FirebaseApp, Analytics and Crashlytics that configure nothing and
// send nothing.
import PackageDescription

let products = ["FirebaseCore", "FirebaseAnalytics", "FirebaseAnalyticsCore", "FirebaseAnalyticsWithoutAdIdSupport", "FirebaseCrashlytics"]

let package = Package(
    name: "Firebase",
    products: products.map { .library(name: $0, targets: [$0]) },
    targets: [.target(name: "Firebase")] + products.map { .target(name: $0, dependencies: ["Firebase"]) }
)
