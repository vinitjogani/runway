import XCTest
import AudioToolbox
import RunwayFoundation

final class CoreAudioTests: XCTestCase {
    func testDefaultOutputDevice() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device), kAudioHardwareNoError)
        XCTAssertNotEqual(device, kAudioObjectUnknown)

        address.mSelector = kAudioHardwarePropertyDevices
        XCTAssertEqual(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), kAudioHardwareNoError)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
        XCTAssertEqual(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids), kAudioHardwareNoError)
        XCTAssertEqual(ids, [device])

        address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name), kAudioHardwareNoError)
        XCTAssertFalse((name as String).isEmpty)

        address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        XCTAssertTrue(AudioObjectHasProperty(device, &address))
        var volume = Float32(0)
        size = 4
        XCTAssertEqual(AudioHardwareServiceGetPropertyData(device, &address, 0, nil, &size, &volume), kAudioHardwareNoError)
        XCTAssertTrue((0...1).contains(volume))

        address.mSelector = runwayFourCharCode("zzzz")
        XCTAssertEqual(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume), kAudioHardwareUnknownPropertyError)
    }
}
