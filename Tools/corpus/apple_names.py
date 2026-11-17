"""Static knowledge about Apple SDK names, used to attribute identifiers to
frameworks. Hand-curated; extend freely (the report only gets better)."""
import re

# Every Apple SDK module an app might import (macOS/iOS). Anything imported
# that is not here, not the app's own module and not Runway's is third-party.
APPLE_MODULES = set('''
Accelerate Accessibility AccessorySetupKit Accounts ActivityKit AddressBook AdServices AdSupport AppIntents AppKit
AppleScriptKit AppleScriptObjC AppTrackingTransparency ApplicationServices AppTrackingTransparency ARKit AssetsLibrary
AudioToolbox AudioUnit AuthenticationServices AutomaticAssessmentConfiguration Automator AVFAudio AVFoundation AVKit
AVRouting BackgroundAssets BackgroundTasks BusinessChat CallKit Carbon CarPlay CFNetwork Charts ClassKit ClockKit CloudKit
Cocoa Collaboration ColorSync Combine Compression Contacts ContactsUI CoreAudio CoreAudioKit CoreAudioTypes CoreBluetooth
CoreData CoreFoundation CoreGraphics CoreHaptics CoreImage CoreLocation CoreLocationUI CoreMedia CoreMediaIO CoreMIDI
CoreML CoreMotion CoreServices CoreSpotlight CoreTelephony CoreText CoreTransferable CoreVideo CoreWLAN CryptoKit
CryptoTokenKit DataDetection DeveloperToolsSupport DeviceActivity DeviceCheck DeviceDiscoveryExtension DiscRecording
DiscRecordingUI DiskArbitration Dispatch Distributed DockKit DriverKit EventKit EventKitUI ExceptionHandling
ExecutionPolicy ExtensionFoundation ExtensionKit ExternalAccessory FamilyControls FileProvider FileProviderUI FinderSync
ForceFeedback Foundation FoundationModels FSKit GameController GameKit GameplayKit GLKit GSS HealthKit Hypervisor
ImageCaptureCore ImageIO InputMethodKit InstallerPlugins IntentsUI Intents IOBluetooth IOBluetoothUI IOKit IOSurface
IOUSBHost JavaScriptCore Kerberos LatentSemanticMapping LinkPresentation LocalAuthentication LocalAuthenticationEmbeddedUI
MailKit ManagedSettings MapKit MediaAccessibility MediaLibrary MediaPlayer MediaToolbox MessageUI Metal MetalFX MetalKit
MetalPerformanceShaders MetalPerformanceShadersGraph MetricKit MLCompute ModelIO MultipeerConnectivity MusicKit
NaturalLanguage NearbyInteraction Network NetworkExtension NotificationCenter Observation OpenAL OpenCL OpenDirectory
OpenGL OSAKit OSLog os PassKit PDFKit PencilKit Photos PhotosUI PreferencePanes ProximityReader PushKit PushToTalk
Quartz QuartzCore QuickLook QuickLookThumbnailing QuickLookUI RealityKit RegexBuilder ReplayKit SafariServices SafetyKit
SceneKit ScreenCaptureKit ScreenSaver ScreenTime ScriptingBridge Security SecurityFoundation SecurityInterface SensitiveContentAnalysis
SensorKit ServiceManagement SharedWithYou ShazamKit Social SoundAnalysis Speech SpriteKit StoreKit Swift SwiftData
SwiftUI Synchronization SystemConfiguration SystemExtensions TabularData Testing ThreadNetwork TipKit Translation
TVMLKit TVServices TVUIKit UIKit UniformTypeIdentifiers UserNotifications UserNotificationsUI VideoSubscriberAccount
VideoToolbox Virtualization Vision VisionKit WatchConnectivity WatchKit WeatherKit WebKit WidgetKit XCTest XPC
_Concurrency Darwin MachO libkern simd zlib sqlite3 SQLite3 CommonCrypto IOKitUI ColorSync ApplicationServices
CoreAudioKit Spatial StoreKitTest AppIntentsUI SwiftData Charts DeveloperToolsSupport Foundation_Private
'''.split())

# Modules a Swift toolchain ships on Linux/Windows (not Runway's job).
TOOLCHAIN_MODULES = {
    'Foundation', 'FoundationEssentials', 'FoundationInternationalization', 'FoundationNetworking', 'FoundationXML',
    'Observation', 'Dispatch', 'XCTest', 'Testing', 'Swift', '_Concurrency', 'Synchronization', 'RegexBuilder',
    'Distributed', 'Glibc', 'Musl', 'WinSDK', 'ucrt', 'CRT', '_StringProcessing',
}

# Umbrella modules and what they pull in.
UMBRELLAS = {
    'Cocoa': ['AppKit', 'Foundation', 'CoreData'],
    'Carbon': ['CoreServices', 'ApplicationServices'],
    'ApplicationServices': ['CoreGraphics', 'CoreText', 'ImageIO', 'ColorSync'],
    'Quartz': ['QuartzCore', 'PDFKit', 'QuickLookUI', 'ImageKit'],
}

# Identifier prefix -> framework. Longest prefix wins. Each entry: (prefix, framework).
# A `k` before any of these (kAXTitleAttribute, kCFBooleanTrue) maps the same way.
PREFIXES = [
    ('NSUserNotification', 'Foundation'),
    ('SCNetwork', 'SystemConfiguration'), ('SCDynamicStore', 'SystemConfiguration'), ('SCPreferences', 'SystemConfiguration'),
    ('SCBondInterface', 'SystemConfiguration'), ('SCVLAN', 'SystemConfiguration'),
    ('SFSpeech', 'Speech'), ('SFSafari', 'SafariServices'), ('SFAuthorization', 'SecurityFoundation'),
    ('ASWebAuthentication', 'AuthenticationServices'), ('ASAuthorization', 'AuthenticationServices'),
    ('FSEvent', 'CoreServices'), ('MDItem', 'CoreServices'), ('MDQuery', 'CoreServices'), ('UTType', 'UniformTypeIdentifiers'),
    ('UTTypeCopy', 'CoreServices'), ('UTTypeCreate', 'CoreServices'), ('UTTypeConforms', 'CoreServices'),
    ('IOHID', 'IOKit'), ('IOPS', 'IOKit'), ('IOPM', 'IOKit'), ('IOSurface', 'IOSurface'),
    ('AudioObject', 'CoreAudio'), ('AudioDevice', 'CoreAudio'), ('AudioHardware', 'CoreAudio'), ('AudioStream', 'CoreAudio'),
    ('AudioServices', 'AudioToolbox'), ('AudioComponent', 'AudioToolbox'), ('AudioUnit', 'AudioToolbox'), ('AudioQueue', 'AudioToolbox'),
    ('AudioFile', 'AudioToolbox'), ('AudioConverter', 'AudioToolbox'), ('AudioBuffer', 'CoreAudioTypes'), ('AudioStreamBasicDescription', 'CoreAudioTypes'),
    ('CGS', 'SkyLight (private CGS)'), ('SLS', 'SkyLight (private)'), ('CoreDisplay', 'CoreDisplay (private)'), ('DisplayServices', 'DisplayServices (private)'),
    ('TIS', 'Carbon'), ('VK_', 'Carbon'), ('UCKey', 'Carbon'), ('LMGet', 'Carbon'),
    ('MTK', 'MetalKit'), ('SKIndex', 'CoreServices (SearchKit)'), ('SKDocument', 'CoreServices (SearchKit)'), ('SKSearch', 'CoreServices (SearchKit)'), ('SKSummary', 'CoreServices (SearchKit)'), ('SKLoadDefaultExtractorPlugIns', 'CoreServices (SearchKit)'), ('MTL', 'Metal'), ('MPS', 'MetalPerformanceShaders'),
    ('SCN', 'SceneKit'), ('SK', 'SpriteKit/StoreKit'), ('SC', 'ScreenCaptureKit'),
    ('NS', 'NS'),  # resolved by ns_framework()
    ('CG', 'CoreGraphics'), ('CA', 'QuartzCore'), ('AV', 'AVFoundation'), ('CM', 'CoreMedia'),
    ('UN', 'UserNotifications'), ('IO', 'IOKit'), ('AX', 'ApplicationServices (Accessibility)'),
    ('CF', 'CoreFoundation'), ('Sec', 'Security'), ('CI', 'CoreImage'), ('CV', 'CoreVideo'), ('VT', 'VideoToolbox'),
    ('MK', 'MapKit'), ('WK', 'WebKit'), ('SM', 'ServiceManagement'), ('QL', 'QuickLook'), ('PDF', 'PDFKit'),
    ('CT', 'CoreText'), ('VN', 'Vision'), ('NL', 'NaturalLanguage'), ('NW', 'Network'), ('VZ', 'Virtualization'),
    ('CB', 'CoreBluetooth'), ('GC', 'GameController'), ('MP', 'MediaPlayer'), ('IK', 'Quartz (ImageKit)'), ('UI', 'UIKit'),
    ('MIDI', 'CoreMIDI'), ('OSA', 'OSAKit'),
] + [(p, 'CoreLocation') for p in ('CLLocation', 'CLGeocoder', 'CLPlacemark', 'CLAuthorizationStatus', 'CLRegion', 'CLHeading', 'CLError')] \
  + [(p, 'Contacts') for p in ('CNContact', 'CNLabel', 'CNPostal', 'CNPhoneNumber', 'CNAuthorizationStatus', 'CNEntityType', 'CNKeyDescriptor', 'CNSaveRequest', 'CNGroup', 'CNContainer')] \
  + [(p, 'EventKit') for p in ('EKEvent', 'EKCalendar', 'EKReminder', 'EKAuthorizationStatus', 'EKSource', 'EKAlarm', 'EKRecurrence', 'EKSpan', 'EKEntityType', 'EKParticipant', 'EKStructuredLocation')] \
  + [(p, 'CloudKit') for p in ('CKContainer', 'CKRecord', 'CKDatabase', 'CKQuery', 'CKSubscription', 'CKError', 'CKShare', 'CKFetch', 'CKModify', 'CKOperation', 'CKAsset', 'CKReference', 'CKNotification', 'CKAccountStatus', 'CKServerChangeToken', 'CKSyncEngine')] \
  + [(p, 'CoreServices') for p in ('LSShared', 'LSCopy', 'LSSet', 'LSOpen', 'LSRegister', 'LSGet', 'LSLaunch', 'LSFind', 'LSItem', 'LSRoles', 'LSApplication', 'LSHandler')] \
  + [(p, 'LocalAuthentication') for p in ('LAContext', 'LAPolicy', 'LAError')] \
  + [(p, 'CoreWLAN') for p in ('CWWiFiClient', 'CWInterface', 'CWNetwork', 'CWChannel', 'CWSecurity', 'CWPHYMode')] \
  + [(p, 'JavaScriptCore') for p in ('JSContext', 'JSValue', 'JSExport', 'JSVirtualMachine')] \
  + [(p, 'DiskArbitration') for p in ('DADisk', 'DASession', 'DARegister', 'DAUnregister', 'DAApprovalSession')] \
  + [(p, 'ScriptingBridge') for p in ('SBApplication', 'SBObject', 'SBElementArray')] \
  + [(p, 'CoreSpotlight') for p in ('CSSearchableItem', 'CSSearchableIndex', 'CSSearchQuery', 'CSCustomAttributeKey')] \
  + [(p, 'CoreServices (Apple Events)') for p in ('AEDesc', 'AEEvent', 'AEKeyword', 'AECreate', 'AESend', 'AEDeterminePermission', 'AEAddress', 'AEDispose')] \
  + [(p, 'OpenDirectory') for p in ('ODSession', 'ODNode', 'ODRecord', 'ODQuery')]
PREFIXES.sort(key=lambda p: -len(p[0]))

# Names that do not follow a prefix scheme, attributed only when the file
# imports the framework (or an umbrella that brings it in).
SWIFT_NAMED = {
    'Combine': ['AnyCancellable', 'PassthroughSubject', 'CurrentValueSubject', 'AnyPublisher', 'Publishers', 'Published',
                'Just', 'Future', 'Deferred', 'Cancellable', 'Subscribers', 'Publisher', 'Subject', 'ObservableObject',
                'ObservableObjectPublisher', 'Fail', 'Empty', 'Record', 'ConnectablePublisher', 'Subscription',
                'Subscriber', 'ImmediateScheduler', 'Scheduler'],
    'os': ['Logger', 'OSLog', 'OSSignposter', 'OSSignpostID', 'OSAllocatedUnfairLock', 'os_log', 'os_signpost',
           'os_unfair_lock', 'os_unfair_lock_lock', 'os_unfair_lock_unlock', 'OSLogType', 'OSLogStore', 'OSLogPrivacy'],
    'OSLog': ['Logger', 'OSLog', 'OSLogStore', 'OSLogEntryLog', 'OSLogEntry', 'OSSignposter'],
    'CryptoKit': ['SHA256', 'SHA384', 'SHA512', 'HMAC', 'SymmetricKey', 'AES', 'ChaChaPoly', 'Insecure', 'P256', 'P384',
                  'Curve25519', 'HKDF', 'SecureEnclave'],
    'SwiftData': ['ModelContainer', 'ModelContext', 'FetchDescriptor', 'PersistentModel', 'ModelConfiguration', 'Schema',
                  'PersistentIdentifier', 'ModelActor', 'Relationship', 'Attribute'],
    'AppIntents': ['AppIntent', 'AppShortcutsProvider', 'AppShortcut', 'IntentParameter', 'AppEntity', 'AppEnum',
                   'EntityQuery', 'IntentResult', 'IntentDialog', 'OpenIntent', 'TypeDisplayRepresentation',
                   'DisplayRepresentation', 'IntentDescription', 'ShowsSnippetView', 'ProvidesDialog', 'ReturnsValue'],
    'WidgetKit': ['Widget', 'WidgetConfiguration', 'TimelineProvider', 'TimelineEntry', 'WidgetCenter', 'StaticConfiguration',
                  'AppIntentConfiguration', 'WidgetBundle', 'WidgetFamily', 'Timeline', 'AppIntentTimelineProvider'],
    'StoreKit': ['Product', 'Transaction', 'AppStore', 'SKStoreReviewController'],
    'Foundation': ['DistributedNotificationCenter', 'NSAppleScript', 'Process', 'Pipe', 'FileHandle', 'XPCListener',
                   'NSXPCConnection', 'NSUserActivity', 'NSFileCoordinator', 'NSMetadataQuery', 'NSUbiquitousKeyValueStore',
                   'ProcessInfo', 'Host', 'NSAppleEventDescriptor', 'NSAppleEventManager', 'NSScriptCommand',
                   'NSUserScriptTask', 'NSUserAppleScriptTask', 'NSUserUnixTask', 'NSBackgroundActivityScheduler', 'Scanner',
                   'NSItemProvider', 'NSFilePresenter', 'NSFileVersion', 'PersonNameComponentsFormatter', 'NSSpellServer',
                   'NSKeyValueObservation', 'NSKeyValueObservedChange', 'NSKeyValueObservingOptions'],
    'Dispatch': ['DispatchSource', 'DispatchSourceFileSystemObject', 'DispatchSourceTimer', 'DispatchSourceSignal',
                 'DispatchSourceProcess', 'DispatchSourceMemoryPressure'],
    'Carbon': ['RegisterEventHotKey', 'UnregisterEventHotKey', 'InstallEventHandler', 'RemoveEventHandler', 'GetApplicationEventTarget',
               'GetEventDispatcherTarget', 'EventHotKeyID', 'EventHotKeyRef', 'EventTypeSpec', 'GetEventParameter', 'EventRef',
               'EventHandlerRef', 'EventHandlerCallRef', 'EventHandlerUPP', 'NewEventHandlerUPP', 'GetEventKind', 'GetEventClass',
               'cmdKey', 'optionKey', 'controlKey', 'shiftKey', 'alphaLock', 'kEventClassKeyboard', 'kEventHotKeyPressed',
               'kEventHotKeyReleased', 'kEventParamDirectObject', 'typeEventHotKeyID', 'noErr', 'eventNotHandledErr',
               'CopySymbolicHotKeys', 'GetCurrentKeyModifiers', 'SendEventToEventTarget', 'kVK_Command', 'PushSymbolicHotKeyMode'],
    'Darwin': ['sysctl', 'sysctlbyname', 'host_statistics64', 'host_processor_info', 'mach_host_self', 'task_info',
               'proc_pidinfo', 'proc_listpids', 'proc_pidpath', 'getifaddrs', 'kinfo_proc', 'mach_absolute_time',
               'mach_timebase_info', 'vm_statistics64', 'vm_deallocate', 'mach_task_self_', 'IFF_UP', 'proc_name',
               'kevent', 'kqueue', 'dlopen', 'dlsym'],
    'ApplicationServices (Accessibility)': ['AXIsProcessTrusted', 'AXIsProcessTrustedWithOptions'],
    'QuartzCore': ['CATransaction', 'CADisplayLink'],
    'Network': ['NWConnection', 'NWListener', 'NWPathMonitor', 'NWEndpoint', 'NWParameters'],
}

# Which import makes a SWIFT_NAMED framework visible.
SWIFT_NAMED_IMPORTS = {
    'Combine': {'Combine', 'SwiftUI'}, 'os': {'os', 'OSLog'}, 'OSLog': {'OSLog'}, 'CryptoKit': {'CryptoKit'},
    'SwiftData': {'SwiftData'}, 'AppIntents': {'AppIntents'}, 'WidgetKit': {'WidgetKit'}, 'StoreKit': {'StoreKit'},
    'Foundation': {'Foundation', 'Cocoa', 'AppKit', 'SwiftUI', 'UIKit', 'Carbon', 'CoreData'},
    'Dispatch': {'Foundation', 'Dispatch', 'Cocoa', 'AppKit', 'SwiftUI'},
    'Carbon': {'Carbon', 'Cocoa'}, 'Darwin': None,  # None: any file
    'ApplicationServices (Accessibility)': None, 'QuartzCore': {'QuartzCore', 'Cocoa', 'AppKit'}, 'Network': {'Network'},
}

# NS-prefixed names that live in Foundation (everything else NS* is AppKit).
FOUNDATION_NS = set('''
NSObject NSObjectProtocol NSString NSMutableString NSNumber NSValue NSArray NSMutableArray NSDictionary NSMutableDictionary
NSSet NSMutableSet NSCountedSet NSOrderedSet NSMutableOrderedSet NSData NSMutableData NSError NSException NSRange NSMakeRange
NSMaxRange NSLocationInRange NSUnionRange NSIntersectionRange NSNotFound NSPredicate NSCompoundPredicate NSComparisonPredicate
NSRegularExpression NSTextCheckingResult NSDataDetector NSAttributedString NSMutableAttributedString NSNotification
NSLock NSRecursiveLock NSCondition NSConditionLock NSCache NSURL NSURLComponents NSURLRequest NSMutableURLRequest
NSURLSession NSUUID NSDate NSDateComponents NSDateFormatter NSTimeZone NSLocale NSCalendar NSCoder NSKeyedArchiver
NSKeyedUnarchiver NSSecureCoding NSCoding NSCopying NSMutableCopying NSIndexSet NSMutableIndexSet NSIndexPath
NSSortDescriptor NSExpression NSFileManager NSUserDefaults NSProcessInfo NSBundle NSThread NSTimer NSRunLoop
NSOperation NSOperationQueue NSBlockOperation NSFileCoordinator NSFilePresenter NSMetadataQuery NSMetadataItem
NSUbiquitousKeyValueStore NSLog NSLocalizedString NSHomeDirectory NSTemporaryDirectory NSUserName NSFullUserName
NSHomeDirectoryForUser NSSearchPathForDirectoriesInDomains NSStringFromClass NSClassFromString NSSelectorFromString
NSStringFromSelector NSStringFromRect NSStringFromPoint NSStringFromSize NSRectFromString NSStringFromRange
NSFastEnumeration NSZone NSPointerArray NSHashTable NSMapTable NSPointerFunctions NSPoint NSRect NSSize NSZeroRect
NSZeroPoint NSZeroSize NSMakeRect NSMakePoint NSMakeSize NSInsetRect NSOffsetRect NSIntegralRect NSUnionRect
NSIntersectionRect NSIntersectsRect NSPointInRect NSMouseInRect NSContainsRect NSEqualRects NSEqualPoints NSEqualSizes
NSIsEmptyRect NSMaxX NSMaxY NSMinX NSMinY NSMidX NSMidY NSWidth NSHeight NSEdgeInsets NSEdgeInsetsZero NSEdgeInsetsMake
NSDecimalNumber NSDecimal NSScanner NSCharacterSet NSMutableCharacterSet NSNull NSProxy NSUserActivity NSItemProvider
NSAppleScript NSAppleEventDescriptor NSAppleEventManager NSXPCConnection NSXPCInterface NSXPCListener NSXPCListenerEndpoint
NSXPCListenerDelegate NSDistributedNotificationCenter NSBackgroundActivityScheduler NSUserNotification NSUserNotificationCenter
NSUserNotificationCenterDelegate NSFileVersion NSFileWrapper NSComparisonResult NSIntegerMax NSIntegerMin NSUIntegerMax
NSStringEncoding NSTask NSPipe NSFileHandle NSHost NSPort NSMachPort NSMessagePort NSSocketPort NSInputStream
NSOutputStream NSStream NSJSONSerialization NSPropertyListSerialization NSXMLParser NSXMLDocument NSXMLElement NSXMLNode
NSNotificationCenter NSNotificationQueue NSValueTransformer NSSecureUnarchiveFromDataTransformer NSKeyValueObservation
NSKeyValueObservedChange NSKeyValueObservingOptions NSKeyValueChangeKey NSKeyValueChange NSMeasurement NSUnit
NSByteCountFormatter NSNumberFormatter NSFormatter NSDateComponentsFormatter NSDateIntervalFormatter NSPersonNameComponents
NSInvocation NSMethodSignature NSScriptCommand NSScriptObjectSpecifier NSScriptClassDescription NSUserScriptTask
NSUserAppleScriptTask NSUserUnixTask NSUnderlyingErrorKey NSLocalizedDescriptionKey NSLocalizedFailureReasonErrorKey
NSFilePathErrorKey NSURLErrorKey NSCocoaErrorDomain NSPOSIXErrorDomain NSOSStatusErrorDomain NSURLErrorDomain
NSDebugDescriptionErrorKey NSHelpAnchorErrorKey NSLocalizedRecoverySuggestionErrorKey NSRecoveryAttempterErrorKey
NSFileReadNoSuchFileError NSFileNoSuchFileError NSFileWriteFileExistsError NSUserCancelledError NSFeatureUnsupportedError
NSFileReadUnknownError NSFileWriteUnknownError NSUbiquitousKeyValueStoreDidChangeExternallyNotification NSMetadataQueryDidUpdate
NSMetadataItemFSNameKey NSMetadataItemPathKey NSMetadataItemURLKey NSMetadataQueryUbiquitousDocumentsScope
NSExtensionContext NSExtensionItem NSSpellServer NSOrthography NSLinguisticTagger NSPurgeableData NSDiscardableContent
NSProgress NSSelectorFromString NSAssertionHandler NSUnarchiver NSArchiver NSCopyObject NSEnumerator NSDirectoryEnumerator
NSLinkedHashMap NSClassDescription NSObjectController NSEC_PER_SEC NSEC_PER_MSEC NSEC_PER_USEC NSUTF8StringEncoding
NSASCIIStringEncoding NSUTF16StringEncoding NSMacOSRomanStringEncoding NSISOLatin1StringEncoding NSWindowsCP1252StringEncoding
NSCaseInsensitiveSearch NSLiteralSearch NSBackwardsSearch NSRegularExpressionSearch NSDiacriticInsensitiveSearch
NSNumericSearch NSAnchoredSearch NSDocumentDirectory NSUserDomainMask NSApplicationSupportDirectory NSCachesDirectory
NSLibraryDirectory NSDownloadsDirectory NSDesktopDirectory NSPicturesDirectory NSMoviesDirectory NSMusicDirectory
NSApplicationDirectory NSSystemDomainMask NSLocalDomainMask NSAllDomainsMask NSFileTypeDirectory NSFileTypeRegular
NSFileSize NSFileModificationDate NSFileCreationDate NSFilePosixPermissions NSFileType NSFileOwnerAccountName
NSFileSystemSize NSFileSystemFreeSize NSURLIsDirectoryKey NSURLNameKey NSURLFileSizeKey NSURLContentModificationDateKey
NSMetadataQueryDidFinishGathering NSMetadataQueryDidFinishGatheringNotification NSMetadataQueryDidUpdateNotification
NSString NSFoundationVersionNumber NSGenericException NSInternalInconsistencyException NSInvalidArgumentException
NSRangeException NSObjectInaccessibleException NSURLErrorCancelled NSURLErrorTimedOut NSURLErrorNotConnectedToInternet
NSPersonNameComponentsFormatter NSListFormatter NSRelativeDateTimeFormatter NSISO8601DateFormatter NSDateInterval
NSCalendarIdentifierGregorian NSTimeIntervalSince1970 NSTimeInterval NSInteger NSUInteger NSSwapBigIntToHost
NSSwapHostIntToBig NSRectEdge NSMinXEdge NSMaxXEdge NSMinYEdge NSMaxYEdge NSAffineTransform NSPointerToStructHashCallBacks
NSSecureCodingKey NSMutableURLRequest NSHTTPURLResponse NSURLResponse NSHTTPCookie NSHTTPCookieStorage NSURLCache
NSURLCredential NSURLProtectionSpace NSURLAuthenticationChallenge NSURLProtocol NSUbiquitousContainerIdentifier
NSFileProviderManager NSDirectoryEnumerationOptions NSXMLDocumentTidyXML NSXMLNodePrettyPrint NSOrderedAscending
NSOrderedDescending NSOrderedSame NSDefaultRunLoopMode NSRunLoopCommonModes NSKeyValueObservingOptionNew
'''.split())

# NS names that are Core Data (Cocoa umbrella pulls it in).
COREDATA_NS = re.compile(r'^NS(Managed|Persistent|Fetch|Entity|AttributeDescription|AttributeType|RelationshipDescription|Batch|Merge|Atomic|Incremental|CoreData|Derived|Expression(Description)|Query(Generation)|Constraint|SaveChanges|MigrationManager|EntityMigrationPolicy|MappingModel|PropertyDescription|Fetched)')

# NS names SwiftUI declares (not AppKit).
SWIFTUI_NS = {'NSViewRepresentable', 'NSViewControllerRepresentable', 'NSApplicationDelegateAdaptor', 'NSHostingView',
              'NSHostingController', 'NSHostingMenu', 'NSHostingSizingOptions', 'NSViewRepresentableContext',
              'NSHostingSceneRepresentation', 'NSGestureRecognizerRepresentable'}

# Foundation API that exists on Darwin but not in swift-corelibs-foundation
# (or is a stub there). Used to flag Foundation gaps on Linux/Windows.
DARWIN_ONLY_FOUNDATION = {
    'NSAppleScript', 'NSAppleEventDescriptor', 'NSAppleEventManager', 'NSScriptCommand', 'NSScriptObjectSpecifier',
    'NSScriptClassDescription', 'NSUserScriptTask', 'NSUserAppleScriptTask', 'NSUserUnixTask', 'NSXPCConnection',
    'NSXPCInterface', 'NSXPCListener', 'NSXPCListenerEndpoint', 'NSXPCListenerDelegate', 'NSDistributedNotificationCenter',
    'DistributedNotificationCenter', 'NSMetadataQuery', 'NSMetadataItem', 'NSUbiquitousKeyValueStore', 'NSFileCoordinator',
    'NSFilePresenter', 'NSFileVersion', 'NSUserNotification', 'NSUserNotificationCenter', 'NSUserNotificationCenterDelegate',
    'NSBackgroundActivityScheduler', 'NSUserActivity', 'NSItemProvider', 'NSSpellServer', 'NSKeyValueObservation',
    'NSKeyValueObservedChange', 'NSLinguisticTagger', 'NSExtensionContext', 'NSExtensionItem', 'NSInvocation',
    'NSMethodSignature', 'NSAppleEventManager', 'NSArchiver', 'NSUnarchiver', 'NSSecureUnarchiveFromDataTransformer',
    'NSFileProviderManager', 'NSMetadataQueryDidFinishGathering', 'NSMetadataQueryDidUpdate',
    'NSMetadataQueryDidFinishGatheringNotification', 'NSMetadataQueryDidUpdateNotification', 'NSUbiquitousContainerIdentifier',
    'NSObjectController', 'NSPurgeableData', 'XPCListener', 'Host',
}

# CoreGraphics/Foundation geometry that swift-corelibs-foundation itself defines.
CORELIBS_PROVIDED = {
    'CGFloat', 'CGPoint', 'CGSize', 'CGRect', 'CGRectEdge', 'CGAffineTransform', 'CGVector',
} | (FOUNDATION_NS - DARWIN_ONLY_FOUNDATION)

SWIFTUI_TYPES = set('''
App Scene View WindowGroup Window Settings MenuBarExtra DocumentGroup UtilityWindow Commands CommandMenu CommandGroup
CommandGroupPlacement CommandsBuilder SceneBuilder ViewBuilder ToolbarContentBuilder Text Image Label Button Toggle
Picker Slider Stepper TextField SecureField TextEditor DatePicker MultiDatePicker ColorPicker Link Menu MenuButton
ProgressView Gauge Divider Spacer VStack HStack ZStack LazyVStack LazyHStack LazyVGrid LazyHGrid Grid GridRow GridItem
ScrollView ScrollViewReader ScrollViewProxy List ForEach Section Group GroupBox Form LabeledContent DisclosureGroup
OutlineGroup NavigationView NavigationStack NavigationSplitView NavigationLink NavigationPath TabView Tab TabSection
Table TableColumn TableRow TableColumnBuilder TableRowBuilder GeometryReader GeometryProxy Color LinearGradient
RadialGradient AngularGradient EllipticalGradient MeshGradient Gradient Rectangle RoundedRectangle
UnevenRoundedRectangle Circle Capsule Ellipse ContainerRelativeShape Path Shape InsettableShape AnyShape AnyView
EmptyView EquatableView TupleView Canvas TimelineView ContentUnavailableView ShareLink PasteButton EditButton
RenameButton ControlGroup ViewThatFits Font Alignment HorizontalAlignment VerticalAlignment Edge EdgeInsets Angle
UnitPoint Animation Transaction AnyTransition Binding State StateObject ObservedObject EnvironmentObject Environment
EnvironmentValues EnvironmentKey AppStorage SceneStorage FocusState FocusedValue FocusedBinding FocusedValues
FocusedValueKey FocusedObject Namespace GestureState PreferenceKey ViewModifier EmptyModifier ModifiedContent
ButtonStyle PrimitiveButtonStyle ToggleStyle LabelStyle ProgressViewStyle TextFieldStyle ListStyle PickerStyle
MenuStyle GroupBoxStyle FormStyle TableStyle GaugeStyle DatePickerStyle DisclosureGroupStyle ControlGroupStyle
LabeledContentStyle NavigationSplitViewStyle TabViewStyle ShapeStyle ButtonStyleConfiguration ToggleStyleConfiguration
LabelStyleConfiguration DragGesture TapGesture LongPressGesture MagnificationGesture MagnifyGesture RotationGesture
RotateGesture SpatialTapGesture Gesture AnyGesture KeyboardShortcut KeyEquivalent EventModifiers KeyPress ToolbarItem
ToolbarItemGroup ToolbarItemPlacement ToolbarContent ToolbarSpacer CustomizableToolbarContent Material
HierarchicalShapeStyle ForegroundStyle BackgroundStyle SelectionShapeStyle TintShapeStyle SeparatorShapeStyle
ImagePaint ContentMode ColorScheme ControlSize Visibility NSViewRepresentable NSViewControllerRepresentable
NSHostingView NSHostingController NSHostingMenu NSApplicationDelegateAdaptor Layout LayoutSubviews LayoutSubview
ProposedViewSize ViewDimensions AnyLayout Spring StrokeStyle FillStyle ImageRenderer OpenURLAction OpenWindowAction
DismissAction DismissWindowAction OpenSettingsAction OpenDocumentAction NewDocumentAction DropDelegate DropInfo
DropProposal PhaseAnimator KeyframeAnimator SearchFieldPlacement Bindable ButtonRole ScenePhase WindowResizability
WindowStyle HiddenTitleBarWindowStyle TitleBarWindowStyle WindowToolbarStyle UnifiedWindowToolbarStyle
ExpandedWindowToolbarStyle UnifiedCompactWindowToolbarStyle SubmitLabel SubmitTriggers TextSelection
DynamicTypeSize LayoutDirection LegibilityWeight ColorSchemeContrast Prominence ScrollIndicatorVisibility
ScrollTargetBehavior ScrollPosition ScrollViewProxy NamedCoordinateSpace CoordinateSpace GlobalCoordinateSpace
LocalCoordinateSpace Anchor AlignmentID ContainerValues ScrollGeometry TextAlignment Toolbar ToolbarRole ToolbarPlacement
SymbolRenderingMode SymbolVariants DefaultButtonStyle PlainButtonStyle BorderlessButtonStyle BorderedButtonStyle
BorderedProminentButtonStyle LinkButtonStyle CheckboxToggleStyle SwitchToggleStyle ButtonToggleStyle DefaultToggleStyle
InsetListStyle SidebarListStyle PlainListStyle BorderedListStyle DefaultListStyle InsetGroupedListStyle
MenuPickerStyle SegmentedPickerStyle InlinePickerStyle RadioGroupPickerStyle PopUpButtonPickerStyle
RoundedBorderTextFieldStyle PlainTextFieldStyle SquareBorderTextFieldStyle GroupedFormStyle ColumnsFormStyle
LinearProgressViewStyle CircularProgressViewStyle BorderlessButtonMenuStyle ButtonMenuStyle DefaultMenuStyle
IconOnlyLabelStyle TitleOnlyLabelStyle TitleAndIconLabelStyle MenuBarExtraStyle WindowMenuBarExtraStyle
PresentedWindowContent ViewAlignedScrollTargetBehavior PagingScrollTargetBehavior ContentShapeKinds HoverPhase
AccessibilityTraits AccessibilityChildBehavior TransactionKey EnvironmentKey Entry Previewable PreviewProvider
PreviewDevice PreviewContext PreviewLayout Transferable FileDocument ReferenceFileDocument FileDocumentConfiguration
FileDocumentReadConfiguration FileDocumentWriteConfiguration FileWrapper OpenWindow AsyncImage AsyncImagePhase
SearchSuggestions SearchScopes ListItemTint ListSectionSpacing BadgeProminence Edge.Set Font.Weight Font.Design
'''.split())

SWIFTUI_WRAPPERS = {'State', 'Binding', 'StateObject', 'ObservedObject', 'EnvironmentObject', 'Environment', 'AppStorage',
                    'SceneStorage', 'FocusState', 'FocusedValue', 'FocusedBinding', 'FocusedObject', 'Namespace',
                    'GestureState', 'FetchRequest', 'SectionedFetchRequest', 'ScaledMetric', 'NSApplicationDelegateAdaptor',
                    'Bindable', 'ViewBuilder', 'SceneBuilder', 'CommandsBuilder', 'ToolbarContentBuilder', 'Previewable',
                    'Entry', 'Query', 'Published', 'Observable', 'ObservationIgnored', 'ObservationTracked', 'Model',
                    'MainActor', 'Sendable', 'Environment'}
NON_SWIFTUI_WRAPPERS = {'Published': 'Combine', 'Observable': 'Observation', 'ObservationIgnored': 'Observation',
                        'ObservationTracked': 'Observation', 'Query': 'SwiftData', 'Model': 'SwiftData',
                        'FetchRequest': 'SwiftUI', 'MainActor': None, 'Sendable': None}

SWIFTUI_MODIFIERS = set('''
padding frame background foregroundColor foregroundStyle font fontWeight fontDesign fontWidth bold italic monospaced
monospacedDigit lineLimit multilineTextAlignment truncationMode minimumScaleFactor opacity cornerRadius clipShape
clipped shadow border overlay offset position rotationEffect rotation3DEffect scaleEffect blur hidden disabled
onTapGesture onLongPressGesture gesture simultaneousGesture highPriorityGesture onAppear onDisappear onChange onReceive
task sheet popover alert confirmationDialog fileImporter fileExporter fileMover fullScreenCover contextMenu help
toolbar navigationTitle navigationSubtitle navigationDestination listStyle buttonStyle toggleStyle pickerStyle
textFieldStyle labelStyle menuStyle progressViewStyle groupBoxStyle formStyle controlSize tint accentColor environment
environmentObject keyboardShortcut focused focusable onSubmit submitLabel onHover onDrag onDrop draggable
dropDestination tag animation transition zIndex layoutPriority fixedSize aspectRatio scaledToFit scaledToFill
resizable renderingMode interpolation antialiased imageScale symbolRenderingMode symbolVariant labelsHidden
edgesIgnoringSafeArea ignoresSafeArea safeAreaInset safeAreaPadding contentShape allowsHitTesting accessibilityLabel
accessibilityHint accessibilityIdentifier accessibilityElement accessibilityAddTraits accessibilityRemoveTraits
accessibilityValue accessibilityHidden accessibilityAction accessibilitySortPriority accessibilityRepresentation
accessibilityChildren preference onPreferenceChange anchorPreference transformPreference backgroundPreferenceValue
overlayPreferenceValue coordinateSpace matchedGeometryEffect mask compositingGroup drawingGroup blendMode saturation
grayscale brightness contrast colorMultiply colorInvert hueRotation luminanceToAlpha textSelection textCase kerning
tracking baselineOffset underline strikethrough lineSpacing listRowInsets listRowBackground listRowSeparator
listRowSeparatorTint listSectionSeparator scrollContentBackground scrollIndicators scrollDisabled scrollPosition
scrollTargetBehavior scrollTargetLayout defaultScrollAnchor searchable searchSuggestions refreshable swipeActions
onDelete onMove onInsert onCommand onExitCommand onMoveCommand onDeleteCommand onCopyCommand onPasteCommand
onCutCommand onKeyPress onOpenURL handlesExternalEvents commands defaultSize windowStyle windowToolbarStyle
windowResizability defaultPosition menuBarExtraStyle menuIndicator buttonBorderShape interactiveDismissDisabled badge
symbolEffect contentTransition sensoryFeedback focusedValue focusedSceneValue focusedObject focusedSceneObject
focusSection prefersDefaultFocus defaultFocus onContinuousHover hoverEffect tabItem tabViewStyle
navigationSplitViewColumnWidth navigationSplitViewStyle navigationViewStyle inspector inspectorColumnWidth tableStyle
gridCellColumns gridColumnAlignment gridCellAnchor gridCellUnsizedAxes alignmentGuide containerRelativeFrame
visualEffect geometryGroup presentationBackground labeledContentStyle disclosureGroupStyle controlGroupStyle
gaugeStyle datePickerStyle toolbarBackground toolbarRole toolbarTitleDisplayMode toolbarVisibility
toolbarBackgroundVisibility backgroundStyle dynamicTypeSize transformEnvironment redacted unredacted privacySensitive
allowsTightening flipsForRightToLeftLayoutDirection onGeometryChange dialogSuppressionToggle dialogIcon
fileDialogDefaultDirectory fileDialogMessage fileDialogConfirmationLabel menuOrder contentMargins typesettingLanguage
scrollClipDisabled scrollBounceBehavior listRowSpacing listItemTint focusEffectDisabled windowBackgroundDragBehavior
windowLevel windowFullScreenBehavior windowMinimizeBehavior windowDismissBehavior windowManagerRole
presentedWindowStyle containerBackground modelContainer modelContext autocorrectionDisabled textContentType
springLoadingBehavior onScrollGeometryChange onScrollPhaseChange onScrollVisibilityChange scrollEdgeEffectStyle
glassEffect backgroundExtensionEffect navigationBarBackButtonHidden toolbarTitleMenu horizontalRadioGroupLayout
pickerStyle selectionDisabled moveDisabled deleteDisabled itemProvider onPasteCommand importsItemProviders
exportsItemProviders copyable cuttable pasteDestination userActivity onContinueUserActivity keyboardShortcut
contextMenu sheet alert previewDisplayName previewLayout previewDevice previewContext environment fixedSize
labelsVisibility menuActionDismissBehavior controlGroupStyle textEditorStyle scrollDismissesKeyboard
presentationDetents presentationDragIndicator presentationCompactAdaptation presentationSizing
navigationBarTitleDisplayMode navigationBarHidden statusBarHidden persistentSystemOverlays defaultAppStorage
monospacedDigit lineHeight layoutValue tableColumnHeaders alternatingRowBackgrounds contextAction
onDragGesture onLongPressGesture accessibilityAddTraits accessibilityShowsLargeContentViewer accessibilityRotor
accessibilityFocused accessibilityActions speechSpellsOutCharacters searchPresentationToolbarBehavior
replaceDisabled findNavigator findDisabled writingToolsBehavior textInputSuggestions onModifierKeysChanged
pointerStyle pointerVisibility windowToolbarFullScreenVisibility toolbarBackgroundVisibility
'''.split())

# Chained calls that are clearly not SwiftUI (used to tidy the 'unclassified' list).
NOT_MODIFIERS = set('''
map filter sink flatMap compactMap receive eraseToAnyPublisher store assign sorted first last joined reduce debounce
removeDuplicates combineLatest prefix dropFirst replacingOccurrences appending append contains forEach throttle
merge zip catch replaceError handleEvents subscribe share delay timeout retry tryMap scan collect switchToLatest
makeConnectable autoconnect publisher sorted lowercased uppercased trimmingCharacters components split count
init isEmpty description debugDescription values keys enumerated reversed shuffled min max allSatisfy firstIndex
lastIndex index distance suffix dropLast removeAll remove insert update then flatMapLatest observe on sync async
resume cancel set get post send fetch decode encode write read data string url path value
'''.split())


def ns_framework(name):
    """Attribute an NS-prefixed name."""
    if name in SWIFTUI_NS:
        return 'SwiftUI'
    if COREDATA_NS.match(name):
        return 'CoreData'
    if name in FOUNDATION_NS or name.startswith(('NSURL', 'NSFile', 'NSXML', 'NSUbiquitous', 'NSMetadata', 'NSKeyValue',
                                                 'NSXPC', 'NSAppleEvent', 'NSUserNotification', 'NSDistributed',
                                                 'NSLocalized', 'NSPersonName', 'NSDateComponent', 'NSHTTP',
                                                 'NSCocoaError', 'NSPOSIX', 'NSOSStatus', 'NSUnderlying')):
        return 'Foundation'
    return 'AppKit'


_PREFIX_RE = None


def prefix_regex():
    global _PREFIX_RE
    if _PREFIX_RE is None:
        alts = '|'.join(re.escape(p) for p, _ in PREFIXES)
        # prefix followed by an uppercase letter (or `_` for kVK_), e.g. NSWindow, kAXRaise, VK_ANSI_A
        _PREFIX_RE = re.compile(r'(?<![\w.])(k?)(' + alts + r')([A-Z_][A-Za-z0-9_]*)')
    return _PREFIX_RE


_FW_OF_PREFIX = dict(PREFIXES)


def framework_of(prefix, name):
    fw = _FW_OF_PREFIX[prefix]
    if fw == 'NS':
        return ns_framework(name)
    if fw == 'SpriteKit/StoreKit':
        return 'StoreKit' if name.startswith(('SKProduct', 'SKPayment', 'SKStore', 'SKReceipt', 'SKRequest')) else 'SpriteKit'
    if fw == 'CoreGraphics' and name.startswith(('CGDisplayStream',)):
        return 'CoreGraphics'
    if fw == 'UniformTypeIdentifiers' and name.startswith('UTType') and len(name) > 6 and name[6:7].islower():
        return 'UniformTypeIdentifiers'
    return fw
