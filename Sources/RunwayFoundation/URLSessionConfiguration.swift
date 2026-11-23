#if canImport(FoundationNetworking)
import FoundationNetworking

extension URLSessionConfiguration {
    /// The host has no iOS background transfer service. Requests and their delegate
    /// callbacks run within the app process using an ordinary session configuration.
    public class func background(withIdentifier identifier: String) -> URLSessionConfiguration {
        .default
    }

    /// A host session cannot arrange for the system to relaunch its app.
    public var sessionSendsLaunchEvents: Bool {
        get { false }
        set { }
    }
}
#endif
