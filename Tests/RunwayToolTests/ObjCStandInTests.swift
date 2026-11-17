import XCTest
@testable import RunwayImport

/// Swift stand-ins generated from Objective-C and C headers.
final class ObjCStandInTests: XCTestCase {
    private func standIns(_ header: String, access: String = "public", known: Set<String> = []) -> String {
        var options = ObjCStandInOptions()
        options.access = access
        options.knownTypes = known
        return objcStandInSource(headers: [header], options: options)
    }

    func testClassWithImporterNames() {
        let out = standIns("""
        #import <Foundation/Foundation.h>
        @interface MASShortcutMonitor : NSObject
        + (instancetype)sharedMonitor;
        - (BOOL)registerShortcut:(MASShortcut *)shortcut withAction:(dispatch_block_t)action;
        - (BOOL)isShortcut:(MASShortcut *)shortcut alreadyTakenInMenu:(NSMenu *)menu explanation:(NSString **)explanation;
        - (instancetype)initWithPath:(NSString *)path;
        @property (nonatomic, readonly) NSString *keyCodeString;
        @end
        """)
        XCTAssertTrue(out.contains("open class MASShortcutMonitor: NSObject {"), out)
        XCTAssertTrue(out.contains("class func shared() -> MASShortcutMonitor!"), out)
        XCTAssertTrue(out.contains("func register(_ shortcut: MASShortcut!, withAction action: (() -> Void)!) -> Bool"), out)
        XCTAssertTrue(out.contains("func isShortcut(_ shortcut: MASShortcut!, alreadyTakenIn menu: NSMenu!, explanation: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Bool"), out)
        XCTAssertTrue(out.contains("public convenience init!(path: String!)"), out)
        XCTAssertTrue(out.contains("open var keyCodeString: String! { \"\" }"), out)
    }

    func testEnumsOptionsAndConstants() {
        let out = standIns("""
        NS_ASSUME_NONNULL_BEGIN
        typedef NS_ENUM(NSInteger, MASShortcutViewStyle) { MASShortcutViewStyleDefault = 0, MASShortcutViewStyleTexturedRect };
        typedef NS_OPTIONS(NSUInteger, FMFlags) { FMFlagsNone = 0, FMFlagsRead = 1 << 0, FMFlagsWrite = 1 << 1 };
        extern NSString *const MASShortcutBinding;
        #define kTemperature 15
        #define FieldBase(type) (type << 16)
        static const uint32_t kScrollX = (FieldBase(6) | 1);
        NS_ASSUME_NONNULL_END
        """)
        XCTAssertTrue(out.contains("public enum MASShortcutViewStyle: Int"), out)
        XCTAssertTrue(out.contains("case `default` = 0"), out)
        XCTAssertTrue(out.contains("case texturedRect = 1"), out)
        XCTAssertTrue(out.contains("public struct FMFlags: OptionSet"), out)
        XCTAssertTrue(out.contains("public static let write = FMFlags(rawValue: 2)"), out)
        XCTAssertTrue(out.contains("MASShortcutBinding: String = \"MASShortcutBinding\""), out)
        XCTAssertTrue(out.contains("public let kTemperature: Int32 = 15"), out)
        XCTAssertTrue(out.contains("public let kScrollX: UInt32 = 393217"), out)
    }

    func testCFunctionsAndCoreFoundationResults() {
        let header = """
        typedef struct __IOHIDEvent *IOHIDEventRef;
        extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(uint32_t display);
        AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *identifier);
        CF_IMPLICIT_BRIDGING_ENABLED
        IOHIDEventRef CGEventCopyIOHIDEvent(CGEventRef);
        CF_IMPLICIT_BRIDGING_DISABLED
        void HBActivate(NSArray<NSNumber *> * _Nonnull items, void (^ _Nonnull completion)(id _Nullable assertion, NSError * _Nullable error));
        """
        let out = standIns(header, access: "internal", known: ["AXUIElement", "CGEvent"])
        XCTAssertTrue(out.contains("final class IOHIDEvent: Hashable"), out)
        XCTAssertTrue(out.contains("typealias IOHIDEventRef = IOHIDEvent"), out)
        // Outside CF_IMPLICIT_BRIDGING a Core Foundation result is Unmanaged; inside it's managed.
        XCTAssertTrue(out.contains("func CoreDisplay_DisplayCreateInfoDictionary(_ display: UInt32) -> Unmanaged<CFDictionary>! { return nil }"), out)
        XCTAssertTrue(out.contains("func CGEventCopyIOHIDEvent(_ arg1: CGEvent!) -> IOHIDEventRef! { return nil }"), out)
        // Error-returning functions report failure.
        XCTAssertTrue(out.contains("func _AXUIElementGetWindow(_ element: AXUIElement!, _ identifier: UnsafeMutablePointer<UInt32>!) -> AXError { return .failure }"), out)
        XCTAssertTrue(out.contains("func HBActivate(_ items: [NSNumber], _ completion: @escaping (Any?, Error?) -> Void)"), out)
        XCTAssertFalse(out.contains("public "), "a bridging header's names are internal")
    }

    func testProtocolWitnessesTakeTheProtocolsTypes() {
        let out = standIns("""
        @protocol OSDHelper
        - (void)showImageAtPath:(NSString *)path withText:(NSString *)text;
        @optional
        - (void)fade;
        @end
        @interface OSDManager : NSObject <OSDHelper>
        + (id)sharedManager;
        - (void)showImageAtPath:(id)path withText:(id)text;
        @end
        """)
        XCTAssertTrue(out.contains("public protocol OSDHelper: AnyObject {"), out)
        XCTAssertTrue(out.contains("open func showImage(atPath path: String!, withText text: String!)"), out)
        XCTAssertFalse(out.contains("atPath path: Any!"), out)
        XCTAssertTrue(out.contains("extension OSDHelper {"), out)
        XCTAssertTrue(out.contains("return _runwaySharedInstance"), out)
    }

    func testReaderTerminatesOnCxx() {
        // C++ isn't understood; the reader must still finish.
        let out = standIns("""
        namespace realm { template <typename T> class Foo { public: Foo(); struct Bar; enum class E : int { a, b }; }; }
        struct ; enum ; struct x *
        @interface A : NSObject - (void)go;
        """)
        XCTAssertTrue(out.contains("import Foundation"), out)
    }

    func testAppleOnlyDetection() {
        XCTAssertTrue(cIncludes(in: "#import <AppKit/AppKit.h>\n").contains { isAppleInclude($0.path) })
        // Portable code's Apple branch doesn't make a target Apple-only.
        let guarded = "#if __APPLE__\n#include <CoreFoundation/CoreFoundation.h>\n#endif\n#include <stdio.h>\n"
        XCTAssertFalse(cIncludes(in: guarded, unguardedOnly: true).contains { isAppleInclude($0.path) })
    }
}
