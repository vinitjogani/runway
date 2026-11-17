// Apple Event codes (CoreServices' AE headers, which ApplicationServices
// includes): event classes and IDs, keywords and the login-item markers.
// Four-character codes (AEEventClass, AEEventID, AEKeyword: UInt32).

private func code(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) } }

public let kCoreEventClass = code("aevt")
public let kAEOpenApplication = code("oapp")
public let kAEReopenApplication = code("rapp")
public let kAEOpenDocuments = code("odoc")
public let kAEPrintDocuments = code("pdoc")
public let kAEOpenContents = code("ocon")
public let kAEQuitApplication = code("quit")
public let kAEShowPreferences = code("pref")
public let kInternetEventClass = code("GURL")
public let kAEGetURL = code("GURL")
public let keyDirectObject = code("----")
public let keyAEPropData = code("prdt")
public let keyAELaunchedAsLogInItem = code("lgit")
public let keyAELaunchedAsServiceItem = code("svit")
public let keyAEQuitReason = code("why?")
public let typeAppleEvent = code("aevt")
public let typeUTF8Text = code("utf8")
