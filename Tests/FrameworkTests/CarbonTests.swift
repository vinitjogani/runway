import XCTest
import Foundation
import Carbon

final class HotKeySink: @unchecked Sendable {
    var ids: [UInt32] = []
    var kinds: [UInt32] = []
    var onEvent: (() -> Void)?
}

private let hotKeyHandler: EventHandlerUPP = { _, event, userData in
    let sink = Unmanaged<HotKeySink>.fromOpaque(userData!).takeUnretainedValue()
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    sink.ids.append(id.id)
    sink.kinds.append(GetEventKind(event))
    sink.onEvent?()
    return noErr
}

final class CarbonTests: XCTestCase {
    func testHotKeyRegistrationAndDispatch() {
        let sink = HotKeySink()
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        var handler: EventHandlerRef?
        XCTAssertEqual(InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 2, &types, Unmanaged.passUnretained(sink).toOpaque(), &handler), noErr)
        defer { _ = RemoveEventHandler(handler) }

        if ProcessInfo.processInfo.environment["DISPLAY"] == nil {
            var ref: EventHotKeyRef?
            // No X server: the shortcut can't be registered, and says so.
            XCTAssertEqual(RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x52554e57, id: 7),
                                               GetApplicationEventTarget(), 0, &ref), eventHotKeyInvalidErr)
        }
        _runwayHotKeysWithoutGrab = true
        defer { _runwayHotKeysWithoutGrab = false }
        var ref: EventHotKeyRef?
        XCTAssertEqual(RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x52554e57, id: 7),
                                           GetApplicationEventTarget(), 0, &ref), noErr)
        var dup: EventHotKeyRef?
        XCTAssertEqual(RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0, id: 8),
                                           GetApplicationEventTarget(), 0, &dup), eventHotKeyExistsErr)
        let fired = expectation(description: "hot key")
        sink.onEvent = { if sink.ids.count == 2 { fired.fulfill() } }
        _runwaySimulateHotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey))
        _runwaySimulateHotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), pressed: false)
        wait(for: [fired], timeout: 2)
        XCTAssertEqual(sink.ids, [7, 7])
        XCTAssertEqual(sink.kinds, [UInt32(kEventHotKeyPressed), UInt32(kEventHotKeyReleased)])
        XCTAssertEqual(UnregisterEventHotKey(ref), noErr)
    }

    func testKeyTranslation() {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)!
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        var dead: UInt32 = 0
        data.withUnsafeBytes { buf in
            let layout = buf.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            _ = UCKeyTranslate(layout, UInt16(kVK_ANSI_2), UInt16(kUCKeyActionDisplay), UInt32((shiftKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        }
        XCTAssertEqual(String(utf16CodeUnits: chars, count: length), "@")
        let id = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(source, kTISPropertyInputSourceID)).takeUnretainedValue() as String
        XCTAssertEqual(id, "com.apple.keylayout.US")
    }

    func testAccessibilityAndEventsAnswerUntrusted() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        XCTAssertFalse(AXIsProcessTrustedWithOptions(prompt))
        let app = AXUIElementCreateApplication(getpid())
        var value: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value), .apiDisabled)
        XCTAssertNil(CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                       eventsOfInterest: CGEventMaskBit(.keyDown), callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil))
        let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(kVK_Return), keyDown: true)!
        e.flags = [.maskCommand]
        XCTAssertEqual(e.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_Return))
        XCTAssertEqual(e.type, .keyDown)
        e.post(tap: .cghidEventTap)
        XCTAssertNotNil(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID))
    }
}
