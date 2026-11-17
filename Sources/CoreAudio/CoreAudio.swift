// CoreAudio's hardware abstraction layer: audio objects queried by
// property address. The system object lists one device, the default
// output, whose volume and mute are the sound server's default sink
// (PulseAudio or PipeWire through `pactl`, when it's installed; otherwise
// full volume, unmuted, read-only). Device names, UIDs, sample rates and
// transport come from it; properties the device doesn't have answer
// kAudioHardwareUnknownPropertyError, as on a Mac.

@_exported import Foundation
@_exported import CoreMedia
import RunwayFoundation

public typealias AudioObjectID = UInt32
public typealias AudioDeviceID = AudioObjectID
public typealias AudioStreamID = AudioObjectID
public typealias AudioClassID = UInt32
public typealias AudioObjectPropertySelector = UInt32
public typealias AudioObjectPropertyScope = UInt32
public typealias AudioObjectPropertyElement = UInt32
public typealias AudioObjectPropertyListenerProc = (AudioObjectID, UInt32, UnsafePointer<AudioObjectPropertyAddress>, UnsafeMutableRawPointer?) -> OSStatus
public typealias AudioObjectPropertyListenerBlock = (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

public struct AudioObjectPropertyAddress: Equatable, Sendable {
    public var mSelector: AudioObjectPropertySelector
    public var mScope: AudioObjectPropertyScope
    public var mElement: AudioObjectPropertyElement
    public init() { mSelector = 0; mScope = 0; mElement = 0 }
    public init(mSelector: AudioObjectPropertySelector, mScope: AudioObjectPropertyScope, mElement: AudioObjectPropertyElement) {
        self.mSelector = mSelector; self.mScope = mScope; self.mElement = mElement
    }
}

public struct AudioValueRange: Sendable { public var mMinimum: Float64 = 0; public var mMaximum: Float64 = 0
    public init() {}; public init(mMinimum: Float64, mMaximum: Float64) { self.mMinimum = mMinimum; self.mMaximum = mMaximum } }

private func fcc(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }

// Errors
public let kAudioHardwareNoError: OSStatus = 0
public let kAudioHardwareNotRunningError = OSStatus(bitPattern: fcc("stop"))
public let kAudioHardwareUnspecifiedError = OSStatus(bitPattern: fcc("what"))
public let kAudioHardwareUnknownPropertyError = OSStatus(bitPattern: fcc("who?"))
public let kAudioHardwareBadPropertySizeError = OSStatus(bitPattern: fcc("!siz"))
public let kAudioHardwareIllegalOperationError = OSStatus(bitPattern: fcc("nope"))
public let kAudioHardwareBadObjectError = OSStatus(bitPattern: fcc("!obj"))
public let kAudioHardwareBadDeviceError = OSStatus(bitPattern: fcc("!dev"))
public let kAudioHardwareUnsupportedOperationError = OSStatus(bitPattern: fcc("unop"))

// Objects, scopes, elements
public let kAudioObjectUnknown: AudioObjectID = 0
public let kAudioObjectSystemObject: AudioObjectID = 1
public let kAudioObjectPropertyScopeGlobal = fcc("glob")
public let kAudioObjectPropertyScopeInput = fcc("inpt")
public let kAudioObjectPropertyScopeOutput = fcc("outp")
public let kAudioObjectPropertyScopePlayThrough = fcc("ptru")
public let kAudioObjectPropertyScopeWildcard = fcc("****")
public let kAudioDevicePropertyScopeInput = kAudioObjectPropertyScopeInput
public let kAudioDevicePropertyScopeOutput = kAudioObjectPropertyScopeOutput
public let kAudioDevicePropertyScopePlayThrough = kAudioObjectPropertyScopePlayThrough
public let kAudioObjectPropertyElementMain: AudioObjectPropertyElement = 0
public let kAudioObjectPropertyElementMaster: AudioObjectPropertyElement = 0
public let kAudioObjectPropertyElementWildcard: AudioObjectPropertyElement = 0xFFFF_FFFF
public let kAudioObjectPropertySelectorWildcard = fcc("****")

// Classes
public let kAudioObjectClassID = fcc("aobj")
public let kAudioSystemObjectClassID = fcc("asys")
public let kAudioDeviceClassID = fcc("adev")
public let kAudioSubDeviceClassID = fcc("asub")
public let kAudioAggregateDeviceClassID = fcc("aagg")
public let kAudioEndPointDeviceClassID = fcc("edev")
public let kAudioEndPointClassID = fcc("endp")
public let kAudioStreamClassID = fcc("astr")

// Object properties
public let kAudioObjectPropertyBaseClass = fcc("bcls")
public let kAudioObjectPropertyClass = fcc("clas")
public let kAudioObjectPropertyOwner = fcc("stdv")
public let kAudioObjectPropertyName = fcc("lnam")
public let kAudioObjectPropertyModelName = fcc("lmod")
public let kAudioObjectPropertyManufacturer = fcc("lmak")
public let kAudioObjectPropertyElementName = fcc("lchn")
public let kAudioObjectPropertyOwnedObjects = fcc("ownd")
public let kAudioObjectPropertyControlList = fcc("ctrl")
public let kAudioObjectPropertySerialNumber = fcc("snum")

// System properties
public let kAudioHardwarePropertyDevices = fcc("dev#")
public let kAudioHardwarePropertyDefaultInputDevice = fcc("dIn ")
public let kAudioHardwarePropertyDefaultOutputDevice = fcc("dOut")
public let kAudioHardwarePropertyDefaultSystemOutputDevice = fcc("sOut")
public let kAudioHardwarePropertyDeviceForUID = fcc("duid")
public let kAudioHardwarePropertyTranslateUIDToDevice = fcc("uidd")

// Device properties
public let kAudioDevicePropertyDeviceUID = fcc("uid ")
public let kAudioDevicePropertyModelUID = fcc("muid")
public let kAudioDevicePropertyTransportType = fcc("tran")
public let kAudioDevicePropertyRelatedDevices = fcc("akin")
public let kAudioDevicePropertyClockDomain = fcc("clkd")
public let kAudioDevicePropertyDeviceIsAlive = fcc("livn")
public let kAudioDevicePropertyDeviceIsRunning = fcc("goin")
public let kAudioDevicePropertyDeviceIsRunningSomewhere = fcc("gone")
public let kAudioDevicePropertyIsRunning = fcc("goin")
public let kAudioDevicePropertyIsHidden = fcc("hidn")
public let kAudioDevicePropertyLatency = fcc("ltnc")
public let kAudioDevicePropertySafetyOffset = fcc("saft")
public let kAudioDevicePropertyStreams = fcc("stm#")
public let kAudioDevicePropertyStreamConfiguration = fcc("slay")
public let kAudioDevicePropertyNominalSampleRate = fcc("nsrt")
public let kAudioDevicePropertyActualSampleRate = fcc("asrt")
public let kAudioDevicePropertyAvailableNominalSampleRates = fcc("nsr#")
public let kAudioDevicePropertyBufferFrameSize = fcc("fsiz")
public let kAudioDevicePropertyBufferFrameSizeRange = fcc("fsz#")
public let kAudioDevicePropertyVolumeScalar = fcc("volm")
public let kAudioDevicePropertyVolumeDecibels = fcc("vold")
public let kAudioDevicePropertyVolumeRangeDecibels = fcc("vdb#")
public let kAudioDevicePropertyVolumeScalarToDecibels = fcc("v2db")
public let kAudioDevicePropertyVolumeDecibelsToScalar = fcc("db2v")
public let kAudioDevicePropertyMute = fcc("mute")
public let kAudioDevicePropertySubVolumeScalar = fcc("svlm")
public let kAudioDevicePropertySubVolumeDecibels = fcc("svld")
public let kAudioDevicePropertySubMute = fcc("smut")
public let kAudioDevicePropertyJackIsConnected = fcc("jack")
public let kAudioDevicePropertyPlayThru = fcc("thru")
public let kAudioDevicePropertyDataSource = fcc("ssrc")
public let kAudioDevicePropertyDataSources = fcc("ssc#")
public let kAudioDevicePropertyDataSourceNameForIDCFString = fcc("lscn")
public let kAudioDevicePropertyClockSource = fcc("csrc")
public let kAudioDevicePropertyClockSources = fcc("csc#")
public let kAudioDevicePropertyClockSourceNameForIDCFString = fcc("lcsn")
public let kAudioDevicePropertyHogMode = fcc("oink")
public let kAudioDevicePropertyPreferredChannelsForStereo = fcc("dch2")
public let kAudioDevicePropertyPreferredChannelLayout = fcc("srnd")
public let kAudioDevicePropertyDriverShouldOwniSub = fcc("isub")
public let kAudioDevicePropertyIOStoppedAbnormally = fcc("stpd")
public let kAudioDevicePropertyConfigurationApplication = fcc("capp")
public let kAudioDeviceProcessorOverload = fcc("over")
public let kAudioHardwareServiceDeviceProperty_VirtualMainVolume = fcc("vmvc")
public let kAudioHardwareServiceDeviceProperty_VirtualMasterVolume = fcc("vmvc")
public let kAudioHardwareServiceDeviceProperty_VirtualMainBalance = fcc("vmbc")
public let kAudioHardwareServiceDeviceProperty_VirtualMasterBalance = fcc("vmbc")

// Streams
public let kAudioStreamPropertyIsActive = fcc("sact")
public let kAudioStreamPropertyDirection = fcc("sdir")
public let kAudioStreamPropertyTerminalType = fcc("term")
public let kAudioStreamPropertyStartingChannel = fcc("schn")
public let kAudioStreamPropertyLatency = fcc("ltnc")
public let kAudioStreamPropertyVirtualFormat = fcc("sfmt")
public let kAudioStreamPropertyAvailableVirtualFormats = fcc("sfma")
public let kAudioStreamPropertyPhysicalFormat = fcc("pft ")
public let kAudioStreamPropertyAvailablePhysicalFormats = fcc("pfta")
public let kAudioStreamTerminalTypeUnknown: UInt32 = 0
public let kAudioStreamTerminalTypeLine = fcc("line")
public let kAudioStreamTerminalTypeDigitalAudioInterface = fcc("spdf")
public let kAudioStreamTerminalTypeSpeaker = fcc("spkr")
public let kAudioStreamTerminalTypeHeadphones = fcc("hdph")
public let kAudioStreamTerminalTypeLFESpeaker = fcc("lfes")
public let kAudioStreamTerminalTypeReceiverSpeaker = fcc("rspk")
public let kAudioStreamTerminalTypeMicrophone = fcc("micr")
public let kAudioStreamTerminalTypeHeadsetMicrophone = fcc("hmic")
public let kAudioStreamTerminalTypeReceiverMicrophone = fcc("rmic")
public let kAudioStreamTerminalTypeTTY = fcc("tty_")
public let kAudioStreamTerminalTypeHDMI = fcc("hdmi")
public let kAudioStreamTerminalTypeDisplayPort = fcc("dprt")

// Transports
public let kAudioDeviceTransportTypeUnknown: UInt32 = 0
public let kAudioDeviceTransportTypeBuiltIn = fcc("bltn")
public let kAudioDeviceTransportTypeAggregate = fcc("grup")
public let kAudioDeviceTransportTypeVirtual = fcc("virt")
public let kAudioDeviceTransportTypePCI = fcc("pci ")
public let kAudioDeviceTransportTypeUSB = fcc("usb ")
public let kAudioDeviceTransportTypeFireWire = fcc("1394")
public let kAudioDeviceTransportTypeBluetooth = fcc("blue")
public let kAudioDeviceTransportTypeBluetoothLE = fcc("blea")
public let kAudioDeviceTransportTypeHDMI = fcc("hdmi")
public let kAudioDeviceTransportTypeDisplayPort = fcc("dprt")
public let kAudioDeviceTransportTypeAirPlay = fcc("airp")
public let kAudioDeviceTransportTypeAVB = fcc("eavb")
public let kAudioDeviceTransportTypeThunderbolt = fcc("thun")

// Formats and aggregate keys
public let kAudioFormatFlagIsNonMixable: UInt32 = 64
public let kAudioAggregateDeviceUIDKey = "uid"
public let kAudioAggregateDeviceNameKey = "name"
public let kAudioAggregateDeviceSubDeviceListKey = "subdevices"
public let kAudioAggregateDeviceMainSubDeviceKey = "master"
public let kAudioSubDeviceUIDKey = "uid"

// MARK: The device model

enum Sink {
    static let deviceID: AudioObjectID = 2
    static let pactl: String? = ["/usr/bin/pactl", "/bin/pactl", "/usr/local/bin/pactl"].first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ args: [String]) -> String? {
        guard let pactl else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pactl)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    static var volume: Float {
        guard let s = run(["get-sink-volume", "@DEFAULT_SINK@"]), let r = s.range(of: #"(\d+)%"#, options: .regularExpression),
              let pct = Float(s[r].dropLast()) else { return 1 }
        return min(max(pct / 100, 0), 1)
    }
    static func setVolume(_ v: Float) -> Bool { run(["set-sink-volume", "@DEFAULT_SINK@", "\(Int((min(max(v, 0), 1) * 100).rounded()))%"]) != nil }
    static var muted: Bool { run(["get-sink-mute", "@DEFAULT_SINK@"])?.contains("yes") ?? false }
    static func setMuted(_ m: Bool) -> Bool { run(["set-sink-mute", "@DEFAULT_SINK@", m ? "1" : "0"]) != nil }
    static var name: String {
        guard let sink = run(["get-default-sink"])?.trimmingCharacters(in: .whitespacesAndNewlines), !sink.isEmpty else { return "Default Output" }
        return sink
    }
    static var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock, DispatchQueue?)] = []
}

enum Value {
    case u32(UInt32), f32(Float32), f64(Float64), string(String), ids([AudioObjectID]), range(AudioValueRange), ranges([AudioValueRange])
    var size: Int {
        switch self {
        case .u32: 4
        case .f32: 4
        case .f64: 8
        case .string: MemoryLayout<UnsafeRawPointer>.size
        case .ids(let a): a.count * 4
        case .range: MemoryLayout<AudioValueRange>.size
        case .ranges(let a): a.count * MemoryLayout<AudioValueRange>.size
        }
    }
}

private func value(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Value? {
    let sel = a.mSelector
    if id == kAudioObjectSystemObject {
        switch sel {
        case kAudioHardwarePropertyDevices, kAudioObjectPropertyOwnedObjects: return .ids([Sink.deviceID])
        case kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice: return .u32(Sink.deviceID)
        case kAudioHardwarePropertyDefaultInputDevice: return .u32(kAudioObjectUnknown)
        case kAudioObjectPropertyClass: return .u32(kAudioSystemObjectClassID)
        case kAudioObjectPropertyName: return .string("Audio System")
        default: return nil
        }
    }
    guard id == Sink.deviceID else { return nil }
    let output = a.mScope != kAudioObjectPropertyScopeInput
    switch sel {
    case kAudioObjectPropertyClass: return .u32(kAudioDeviceClassID)
    case kAudioObjectPropertyBaseClass: return .u32(kAudioObjectClassID)
    case kAudioObjectPropertyOwner: return .u32(kAudioObjectSystemObject)
    case kAudioObjectPropertyName: return .string(Sink.name)
    case kAudioObjectPropertyModelName: return .string(Sink.name)
    case kAudioObjectPropertyManufacturer: return .string(Sink.pactl == nil ? "Runway" : "PulseAudio")
    case kAudioDevicePropertyDeviceUID: return .string("runway-default-output")
    case kAudioDevicePropertyModelUID: return .string("runway-default-output-model")
    case kAudioDevicePropertyTransportType: return .u32(kAudioDeviceTransportTypeBuiltIn)
    case kAudioDevicePropertyDeviceIsAlive: return .u32(1)
    case kAudioDevicePropertyDeviceIsRunning, kAudioDevicePropertyDeviceIsRunningSomewhere: return .u32(0)
    case kAudioDevicePropertyIsHidden: return .u32(0)
    case kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset: return .u32(0)
    case kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyActualSampleRate: return .f64(48000)
    case kAudioDevicePropertyAvailableNominalSampleRates: return .ranges([AudioValueRange(mMinimum: 44100, mMaximum: 44100), AudioValueRange(mMinimum: 48000, mMaximum: 48000)])
    case kAudioDevicePropertyBufferFrameSize: return .u32(512)
    case kAudioDevicePropertyBufferFrameSizeRange: return .range(AudioValueRange(mMinimum: 64, mMaximum: 4096))
    case kAudioDevicePropertyStreams: return .ids(output ? [3] : [])
    case kAudioDevicePropertyRelatedDevices: return .ids([Sink.deviceID])
    case kAudioDevicePropertyPreferredChannelsForStereo: return .ids([1, 2])
    case kAudioDevicePropertyHogMode: return .u32(UInt32(bitPattern: -1))
    case kAudioDevicePropertyJackIsConnected: return .u32(1)
    case kAudioDevicePropertyVolumeScalar, kAudioHardwareServiceDeviceProperty_VirtualMainVolume:
        return output ? .f32(Sink.volume) : nil
    case kAudioDevicePropertyVolumeDecibels: return output ? .f32(20 * log10(max(Sink.volume, 0.0001))) : nil
    case kAudioHardwareServiceDeviceProperty_VirtualMainBalance: return output ? .f32(0.5) : nil
    case kAudioDevicePropertyMute: return output ? .u32(Sink.muted ? 1 : 0) : nil
    default: return nil
    }
}

private func settable(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
    id == Sink.deviceID && Sink.pactl != nil &&
        [kAudioDevicePropertyVolumeScalar, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute].contains(a.mSelector)
}

private func notify(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) {
    for (addr, block, queue) in Sink.listeners where addr.mSelector == a.mSelector || addr.mSelector == kAudioObjectPropertySelectorWildcard {
        var copy = a
        let run = { withUnsafePointer(to: &copy) { block(1, $0) } }
        if let queue { queue.async(execute: run) } else { run() }
    }
}

// MARK: Functions

public func AudioObjectHasProperty(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>) -> Bool {
    value(inObjectID, inAddress.pointee) != nil
}

public func AudioObjectIsPropertySettable(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
                                          _ outIsSettable: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus {
    guard value(inObjectID, inAddress.pointee) != nil else { return kAudioHardwareUnknownPropertyError }
    outIsSettable.pointee = DarwinBoolean(settable(inObjectID, inAddress.pointee))
    return kAudioHardwareNoError
}

public func AudioObjectGetPropertyDataSize(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
                                           _ inQualifierDataSize: UInt32, _ inQualifierData: UnsafeRawPointer?,
                                           _ outDataSize: UnsafeMutablePointer<UInt32>) -> OSStatus {
    guard inObjectID == kAudioObjectSystemObject || inObjectID == Sink.deviceID else { return kAudioHardwareBadObjectError }
    guard let v = value(inObjectID, inAddress.pointee) else { return kAudioHardwareUnknownPropertyError }
    outDataSize.pointee = UInt32(v.size)
    return kAudioHardwareNoError
}

public func AudioObjectGetPropertyData(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
                                       _ inQualifierDataSize: UInt32, _ inQualifierData: UnsafeRawPointer?,
                                       _ ioDataSize: UnsafeMutablePointer<UInt32>, _ outData: UnsafeMutableRawPointer) -> OSStatus {
    guard inObjectID == kAudioObjectSystemObject || inObjectID == Sink.deviceID else { return kAudioHardwareBadObjectError }
    guard let v = value(inObjectID, inAddress.pointee) else { return kAudioHardwareUnknownPropertyError }
    let room = Int(ioDataSize.pointee)
    switch v {
    case .u32(let x): guard room >= 4 else { return kAudioHardwareBadPropertySizeError }; outData.storeBytes(of: x, as: UInt32.self)
    case .f32(let x): guard room >= 4 else { return kAudioHardwareBadPropertySizeError }; outData.storeBytes(of: x, as: Float32.self)
    case .f64(let x): guard room >= 8 else { return kAudioHardwareBadPropertySizeError }; outData.storeBytes(of: x, as: Float64.self)
    case .string(let s):
        guard room >= MemoryLayout<UnsafeRawPointer>.size else { return kAudioHardwareBadPropertySizeError }
        outData.storeBytes(of: Unmanaged.passRetained(s as NSString), as: Unmanaged<NSString>.self)
    case .ids(let ids):
        let n = min(ids.count, room / 4)
        for i in 0..<n { outData.storeBytes(of: ids[i], toByteOffset: i * 4, as: UInt32.self) }
        ioDataSize.pointee = UInt32(n * 4)
        return kAudioHardwareNoError
    case .range(let r): guard room >= MemoryLayout<AudioValueRange>.size else { return kAudioHardwareBadPropertySizeError }
        outData.storeBytes(of: r, as: AudioValueRange.self)
    case .ranges(let rs):
        let size = MemoryLayout<AudioValueRange>.size
        let n = min(rs.count, room / size)
        for i in 0..<n { outData.storeBytes(of: rs[i], toByteOffset: i * size, as: AudioValueRange.self) }
        ioDataSize.pointee = UInt32(n * size)
        return kAudioHardwareNoError
    }
    ioDataSize.pointee = UInt32(v.size)
    return kAudioHardwareNoError
}

public func AudioObjectSetPropertyData(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
                                       _ inQualifierDataSize: UInt32, _ inQualifierData: UnsafeRawPointer?,
                                       _ inDataSize: UInt32, _ inData: UnsafeRawPointer) -> OSStatus {
    let a = inAddress.pointee
    guard value(inObjectID, a) != nil else { return kAudioHardwareUnknownPropertyError }
    guard settable(inObjectID, a) else { return kAudioHardwareUnsupportedOperationError }
    let ok: Bool
    switch a.mSelector {
    case kAudioDevicePropertyMute: ok = Sink.setMuted(inData.load(as: UInt32.self) != 0)
    default: ok = Sink.setVolume(inData.load(as: Float32.self))
    }
    guard ok else { return kAudioHardwareUnspecifiedError }
    notify(inObjectID, a)
    return kAudioHardwareNoError
}

public func AudioObjectAddPropertyListenerBlock(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
                                                _ inDispatchQueue: DispatchQueue?, _ inListener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
    Sink.listeners.append((inAddress.pointee, inListener, inDispatchQueue))
    return kAudioHardwareNoError
}

public func AudioObjectRemovePropertyListenerBlock(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
                                                   _ inDispatchQueue: DispatchQueue?, _ inListener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
    Sink.listeners.removeAll { $0.0 == inAddress.pointee }
    return kAudioHardwareNoError
}

public func AudioObjectAddPropertyListener(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
                                           _ inListener: @escaping AudioObjectPropertyListenerProc, _ inClientData: UnsafeMutableRawPointer?) -> OSStatus {
    nonisolated(unsafe) let client = inClientData
    let proc = inListener
    let objectID = inObjectID
    Sink.listeners.append((inAddress.pointee, { n, a in _ = proc(objectID, n, a, client) }, nil))
    return kAudioHardwareNoError
}

public func AudioObjectRemovePropertyListener(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>,
                                              _ inListener: @escaping AudioObjectPropertyListenerProc, _ inClientData: UnsafeMutableRawPointer?) -> OSStatus {
    Sink.listeners.removeAll { $0.0 == inAddress.pointee }
    return kAudioHardwareNoError
}

public func AudioDeviceStart(_ inDevice: AudioObjectID, _ inProcID: UnsafeRawPointer?) -> OSStatus { kAudioHardwareUnsupportedOperationError }
public func AudioDeviceStop(_ inDevice: AudioObjectID, _ inProcID: UnsafeRawPointer?) -> OSStatus { kAudioHardwareNoError }
public func AudioHardwareCreateAggregateDevice(_ description: CFDictionary, _ outDeviceID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus {
    kAudioHardwareUnsupportedOperationError
}
public func AudioHardwareDestroyAggregateDevice(_ inDeviceID: AudioObjectID) -> OSStatus { kAudioHardwareBadDeviceError }


/// A stream format with the range of sample rates it supports.
public struct AudioStreamRangedDescription: Sendable {
    public var mFormat: AudioStreamBasicDescription
    public var mSampleRateRange: AudioValueRange
    public init() { mFormat = AudioStreamBasicDescription(); mSampleRateRange = AudioValueRange() }
    public init(mFormat: AudioStreamBasicDescription, mSampleRateRange: AudioValueRange) { self.mFormat = mFormat; self.mSampleRateRange = mSampleRateRange }
}


/// Input and output buffers of a property that translates one value into another.
public struct AudioValueTranslation {
    public var mInputData: UnsafeMutableRawPointer
    public var mInputDataSize: UInt32
    public var mOutputData: UnsafeMutableRawPointer
    public var mOutputDataSize: UInt32
    public init(mInputData: UnsafeMutableRawPointer, mInputDataSize: UInt32, mOutputData: UnsafeMutableRawPointer, mOutputDataSize: UInt32) {
        self.mInputData = mInputData; self.mInputDataSize = mInputDataSize; self.mOutputData = mOutputData; self.mOutputDataSize = mOutputDataSize
    }
}


// MARK: Channel layouts (CoreAudioBaseTypes)

public typealias AudioChannelLabel = UInt32
public typealias AudioChannelLayoutTag = UInt32

public struct AudioChannelFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let rectangularCoordinates = AudioChannelFlags(rawValue: 1 << 0)
    public static let sphericalCoordinates = AudioChannelFlags(rawValue: 1 << 1)
    public static let meters = AudioChannelFlags(rawValue: 1 << 2)
}

public struct AudioChannelBitmap: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public struct AudioChannelDescription: Sendable {
    public var mChannelLabel: AudioChannelLabel = 0
    public var mChannelFlags: AudioChannelFlags = []
    public var mCoordinates: (Float32, Float32, Float32) = (0, 0, 0)
    public init() {}
    public init(mChannelLabel: AudioChannelLabel, mChannelFlags: AudioChannelFlags, mCoordinates: (Float32, Float32, Float32)) {
        self.mChannelLabel = mChannelLabel; self.mChannelFlags = mChannelFlags; self.mCoordinates = mCoordinates
    }
}

public struct AudioChannelLayout: Sendable {
    public var mChannelLayoutTag: AudioChannelLayoutTag = 0
    public var mChannelBitmap: AudioChannelBitmap = []
    public var mNumberChannelDescriptions: UInt32 = 0
    public var mChannelDescriptions: (AudioChannelDescription) = AudioChannelDescription()
    public init() {}
    public init(mChannelLayoutTag: AudioChannelLayoutTag, mChannelBitmap: AudioChannelBitmap, mNumberChannelDescriptions: UInt32, mChannelDescriptions: (AudioChannelDescription)) {
        self.mChannelLayoutTag = mChannelLayoutTag; self.mChannelBitmap = mChannelBitmap
        self.mNumberChannelDescriptions = mNumberChannelDescriptions; self.mChannelDescriptions = mChannelDescriptions
    }
}

public let kAudioChannelLayoutTag_UseChannelDescriptions: AudioChannelLayoutTag = 0
public let kAudioChannelLayoutTag_UseChannelBitmap: AudioChannelLayoutTag = 1 << 16
public let kAudioChannelLayoutTag_Mono: AudioChannelLayoutTag = (100 << 16) | 1
public let kAudioChannelLayoutTag_Stereo: AudioChannelLayoutTag = (101 << 16) | 2
public let kAudioChannelLabel_Unknown: AudioChannelLabel = 0xFFFF_FFFF
public let kAudioChannelLabel_Left: AudioChannelLabel = 1
public let kAudioChannelLabel_Right: AudioChannelLabel = 2
public let kAudioChannelLabel_Center: AudioChannelLabel = 3
public let kAudioChannelLabel_Mono: AudioChannelLabel = 42
