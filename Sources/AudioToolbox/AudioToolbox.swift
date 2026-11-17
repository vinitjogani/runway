// AudioToolbox: system sounds and the hardware service calls apps use
// for the "virtual main volume", over Runway's CoreAudio (which it
// re-exports, as on the Mac).

@_exported import CoreAudio
import Foundation
import RunwayFoundation

public typealias SystemSoundID = UInt32
public let kSystemSoundID_UserPreferredAlert: SystemSoundID = 0x1000
public let kSystemSoundID_FlashScreen: SystemSoundID = 0x0FFE
public let kSystemSoundID_Vibrate: SystemSoundID = 0x00000FFF

private final class SoundRegistry: @unchecked Sendable {
    static let shared = SoundRegistry()
    let lock = NSLock()
    var urls: [SystemSoundID: URL] = [:]
    var next: SystemSoundID = 0x2000
}

public func AudioServicesCreateSystemSoundID(_ inFileURL: CFURL, _ outSystemSoundID: UnsafeMutablePointer<SystemSoundID>) -> OSStatus {
    let r = SoundRegistry.shared
    r.lock.withLock {
        r.urls[r.next] = inFileURL as URL
        outSystemSoundID.pointee = r.next
        r.next += 1
    }
    return 0
}

public func AudioServicesDisposeSystemSoundID(_ inSystemSoundID: SystemSoundID) -> OSStatus {
    let r = SoundRegistry.shared
    r.lock.withLock { _ = r.urls.removeValue(forKey: inSystemSoundID) }
    return 0
}

/// Plays a registered sound file (through the sound server's player when
/// there is one), or the terminal bell for the system alert sounds.
public func AudioServicesPlaySystemSound(_ inSystemSoundID: SystemSoundID) {
    let r = SoundRegistry.shared
    let url = r.lock.withLock { r.urls[inSystemSoundID] }
    guard let url else {
        FileHandle.standardError.write(Data("\u{7}".utf8))
        return
    }
    for player in ["/usr/bin/paplay", "/usr/bin/pw-play", "/usr/bin/aplay"] where FileManager.default.isExecutableFile(atPath: player) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: player)
        p.arguments = [url.path]
        try? p.run()
        return
    }
}
public func AudioServicesPlayAlertSound(_ inSystemSoundID: SystemSoundID) { AudioServicesPlaySystemSound(inSystemSoundID) }
public func AudioServicesPlaySystemSoundWithCompletion(_ inSystemSoundID: SystemSoundID, _ inCompletionBlock: (() -> Void)?) {
    AudioServicesPlaySystemSound(inSystemSoundID)
    inCompletionBlock?()
}
public func AudioServicesPlayAlertSoundWithCompletion(_ inSystemSoundID: SystemSoundID, _ inCompletionBlock: (() -> Void)?) {
    AudioServicesPlaySystemSoundWithCompletion(inSystemSoundID, inCompletionBlock)
}

// The hardware service calls are the HAL's with a different name.
public func AudioHardwareServiceHasProperty(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>) -> Bool {
    AudioObjectHasProperty(id, address)
}
public func AudioHardwareServiceGetPropertyDataSize(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qSize: UInt32,
                                                    _ q: UnsafeRawPointer?, _ outSize: UnsafeMutablePointer<UInt32>) -> OSStatus {
    AudioObjectGetPropertyDataSize(id, address, qSize, q, outSize)
}
public func AudioHardwareServiceGetPropertyData(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qSize: UInt32,
                                                _ q: UnsafeRawPointer?, _ ioSize: UnsafeMutablePointer<UInt32>, _ out: UnsafeMutableRawPointer) -> OSStatus {
    AudioObjectGetPropertyData(id, address, qSize, q, ioSize, out)
}
public func AudioHardwareServiceSetPropertyData(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qSize: UInt32,
                                                _ q: UnsafeRawPointer?, _ size: UInt32, _ data: UnsafeRawPointer) -> OSStatus {
    AudioObjectSetPropertyData(id, address, qSize, q, size, data)
}
public func AudioHardwareServiceIsPropertySettable(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                                   _ out: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus {
    AudioObjectIsPropertySettable(id, address, out)
}
