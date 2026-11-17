// NSAccessibility: the roles, notifications and attributes apps set on their
// views (`setAccessibilityLabel(_:)`, `setAccessibilityRole(_:)`…), kept on
// each view as AppKit does, and the actions assistive technology performs
// (`accessibilityPerformPress()`…), which views override.

import Foundation

/// The accessibility namespace: roles, subroles, notifications and posting.
public enum NSAccessibility {
    public struct Role: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let application = Role("AXApplication"), browser = Role("AXBrowser"), busyIndicator = Role("AXBusyIndicator")
        public static let button = Role("AXButton"), cell = Role("AXCell"), checkBox = Role("AXCheckBox"), colorWell = Role("AXColorWell")
        public static let column = Role("AXColumn"), comboBox = Role("AXComboBox"), disclosureTriangle = Role("AXDisclosureTriangle")
        public static let drawer = Role("AXDrawer"), group = Role("AXGroup"), grid = Role("AXGrid"), growArea = Role("AXGrowArea")
        public static let handle = Role("AXHandle"), helpTag = Role("AXHelpTag"), image = Role("AXImage"), incrementor = Role("AXIncrementor")
        public static let layoutArea = Role("AXLayoutArea"), layoutItem = Role("AXLayoutItem"), levelIndicator = Role("AXLevelIndicator")
        public static let link = Role("AXLink"), list = Role("AXList"), matte = Role("AXMatte"), menu = Role("AXMenu")
        public static let menuBar = Role("AXMenuBar"), menuBarItem = Role("AXMenuBarItem"), menuButton = Role("AXMenuButton")
        public static let menuItem = Role("AXMenuItem"), outline = Role("AXOutline"), pageRole = Role("AXPage"), popUpButton = Role("AXPopUpButton")
        public static let popover = Role("AXPopover"), progressIndicator = Role("AXProgressIndicator"), radioButton = Role("AXRadioButton")
        public static let radioGroup = Role("AXRadioGroup"), relevanceIndicator = Role("AXRelevanceIndicator"), row = Role("AXRow")
        public static let ruler = Role("AXRuler"), rulerMarker = Role("AXRulerMarker"), scrollArea = Role("AXScrollArea")
        public static let scrollBar = Role("AXScrollBar"), sheet = Role("AXSheet"), slider = Role("AXSlider"), sortButton = Role("AXSortButton")
        public static let splitGroup = Role("AXSplitGroup"), splitter = Role("AXSplitter"), staticText = Role("AXStaticText")
        public static let systemWide = Role("AXSystemWide"), tabGroup = Role("AXTabGroup"), table = Role("AXTable"), textArea = Role("AXTextArea")
        public static let textField = Role("AXTextField"), toolbar = Role("AXToolbar"), unknown = Role("AXUnknown")
        public static let valueIndicator = Role("AXValueIndicator"), window = Role("AXWindow")
    }
    public struct Subrole: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let closeButton = Subrole("AXCloseButton"), contentList = Subrole("AXContentList"), descriptionList = Subrole("AXDescriptionList")
        public static let minimizeButton = Subrole("AXMinimizeButton"), zoomButton = Subrole("AXZoomButton")
        public static let fullScreenButton = Subrole("AXFullScreenButton"), systemDialog = Subrole("AXSystemDialog"), systemFloatingWindow = Subrole("AXSystemFloatingWindow")
        public static let incrementArrow = Subrole("AXIncrementArrow"), decrementArrow = Subrole("AXDecrementArrow"), incrementPage = Subrole("AXIncrementPage")
        public static let decrementPage = Subrole("AXDecrementPage"), sortButton = Subrole("AXSortButton")
        public static let timeline = Subrole("AXTimeline"), ratingIndicator = Subrole("AXRatingIndicator"), definitionList = Subrole("AXDefinitionList")
        public static let sectionListSubrole = Subrole("AXSectionList"), collectionListSubrole = Subrole("AXCollectionList"), tabButtonSubrole = Subrole("AXTabButton")
        public static let dialog = Subrole("AXDialog"), floatingWindow = Subrole("AXFloatingWindow"), outlineRow = Subrole("AXOutlineRow")
        public static let searchField = Subrole("AXSearchField"), secureTextField = Subrole("AXSecureTextField")
        public static let standardWindow = Subrole("AXStandardWindow"), switch_ = Subrole("AXSwitch"), tabButton = Subrole("AXTabButton")
        public static let tableRow = Subrole("AXTableRow"), textLink = Subrole("AXTextLink"), toggle = Subrole("AXToggle")
        public static let toolbarButton = Subrole("AXToolbarButton"), unknown = Subrole("AXUnknown")
    }
    public struct Notification: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let announcementRequested = Notification("AXAnnouncementRequested")
        public static let focusedUIElementChanged = Notification("AXFocusedUIElementChanged")
        public static let layoutChanged = Notification("AXLayoutChanged"), valueChanged = Notification("AXValueChanged")
        public static let titleChanged = Notification("AXTitleChanged"), selectedChildrenChanged = Notification("AXSelectedChildrenChanged")
        public static let selectedTextChanged = Notification("AXSelectedTextChanged"), selectedRowsChanged = Notification("AXSelectedRowsChanged")
        public static let created = Notification("AXCreated"), uiElementDestroyed = Notification("AXUIElementDestroyed")
        public static let rowCountChanged = Notification("AXRowCountChanged"), resized = Notification("AXResized"), moved = Notification("AXMoved")
    }
    public struct NotificationUserInfoKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let announcement = NotificationUserInfoKey("AXAnnouncementKey"), priority = NotificationUserInfoKey("AXPriorityKey")
        public static let uiElements = NotificationUserInfoKey("AXUIElementsKey")
    }
    public enum PriorityLevel: Int, Sendable { case low = 10, medium = 50, high = 90 }

    /// Notifications posted for assistive technology, most recent last
    /// (Runway keeps them for inspection; there's no AX server to send them to).
    @preconcurrency @MainActor public private(set) static var postedNotifications: [(element: AnyObject, notification: Notification, userInfo: [NotificationUserInfoKey: Any]?)] = []

    @preconcurrency @MainActor public static func post(element: Any, notification: Notification, userInfo: [NotificationUserInfoKey: Any]? = nil) {
        postedNotifications.append((element as AnyObject, notification, userInfo))
        if postedNotifications.count > 64 { postedNotifications.removeFirst(postedNotifications.count - 64) }
    }
    @preconcurrency @MainActor public static func post(element: Any, notification: Notification) {
        post(element: element, notification: notification, userInfo: nil)
    }
}

/// What a view says about itself to assistive technology.
struct AccessibilityAttributes {
    var element: Bool?
    var label: String?
    var title: String?
    var help: String?
    var identifier: String?
    var role: NSAccessibility.Role?
    var subrole: NSAccessibility.Subrole?
    var roleDescription: String?
    var value: Any?
    var hidden = false
    var enabled = true
    var selected = false
    var focused = false
    var children: [Any]?
    weak var parent: AnyObject?
}

extension NSWorkspace {
    /// Whether the user asked for less motion (`RUNWAY_REDUCE_MOTION=1`).
    public var accessibilityDisplayShouldReduceMotion: Bool {
        let v = ProcessInfo.processInfo.environment["RUNWAY_REDUCE_MOTION"]
        return v == "1" || v == "true"
    }
    public var accessibilityDisplayShouldReduceTransparency: Bool { false }
    public var accessibilityDisplayShouldIncreaseContrast: Bool { false }
    public var accessibilityDisplayShouldDifferentiateWithoutColor: Bool { false }
    public var accessibilityDisplayShouldInvertColors: Bool { false }
    public var isVoiceOverEnabled: Bool { false }
    public var isSwitchControlEnabled: Bool { false }
}
