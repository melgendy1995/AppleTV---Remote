// Probe v2: enumerate every capture device the Mac can see, including
// screen-capture-class devices (iOS/tvOS wireless capture) which are hidden
// from AVFoundation by default. QuickTime unhides them by setting the CMIO
// property kCMIOHardwarePropertyAllowScreenCaptureDevices=1 on launch.
//
// Run:   swift mac-agent/probe/list_devices.swift
// If macOS prompts for Camera/Local Network access, grant it and re-run.

import AVFoundation
import CoreMediaIO
import Foundation

// MARK: - Unlock screen-capture-class CMIO devices (what QuickTime does)

func enableScreenCaptureDevices() {
    var prop = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var allow: UInt32 = 1
    let status = CMIOObjectSetPropertyData(
        CMIOObjectID(kCMIOObjectSystemObject),
        &prop, 0, nil,
        UInt32(MemoryLayout<UInt32>.size), &allow
    )
    print("CMIO AllowScreenCaptureDevices=1 → OSStatus \(status) \(status == 0 ? "(ok)" : "(FAILED)")")

    // Some macOS builds also gate wireless devices behind this flag.
    var wprop = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    let wstatus = CMIOObjectSetPropertyData(
        CMIOObjectID(kCMIOObjectSystemObject),
        &wprop, 0, nil,
        UInt32(MemoryLayout<UInt32>.size), &allow
    )
    print("CMIO AllowWirelessScreenCaptureDevices=1 → OSStatus \(wstatus) \(wstatus == 0 ? "(ok)" : "(not-present or FAILED)")")
}

// MARK: - AVFoundation enumeration

func label(_ s: String) { print("\n=== \(s) ===") }

func dump(_ d: AVCaptureDevice) {
    print("• \(d.localizedName)")
    print("    uniqueID:      \(d.uniqueID)")
    print("    modelID:       \(d.modelID)")
    print("    manufacturer:  \(d.manufacturer)")
    print("    deviceType:    \(d.deviceType.rawValue)")
    print("    connected:     \(d.isConnected)")
    if d.hasMediaType(.video) || d.hasMediaType(.muxed) {
        let fmts = d.formats.prefix(3).map { f -> String in
            let d = f.formatDescription
            let dim = CMVideoFormatDescriptionGetDimensions(d)
            return "\(dim.width)x\(dim.height)"
        }
        print("    formats:       \(fmts.joined(separator: ", "))\(d.formats.count > 3 ? " …(+\(d.formats.count - 3))" : "")")
    }
}

func avfEnumerate() {
    let types: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera, .external, .continuityCamera, .microphone,
    ]
    let v = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    label("AVFoundation — video (\(v.count))"); v.forEach(dump)

    let m = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .muxed, position: .unspecified).devices
    label("AVFoundation — muxed (\(m.count))"); m.forEach(dump)

    let a = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
    label("AVFoundation — audio (\(a.count))"); a.forEach(dump)
}

// MARK: - Raw CoreMediaIO enumeration (bypasses AVFoundation filters)

func cmioString(_ id: CMIOObjectID, _ selector: UInt32) -> String? {
    var addr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(selector),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var dataSize: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(id, &addr, 0, nil, &dataSize) == 0 else { return nil }
    var cf: Unmanaged<CFString>?
    var used: UInt32 = 0
    let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
        CMIOObjectGetPropertyData(id, &addr, 0, nil, dataSize, &used, ptr)
    }
    guard status == 0, let s = cf?.takeRetainedValue() else { return nil }
    return s as String
}

func cmioEnumerate() {
    var addr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var dataSize: UInt32 = 0
    let s1 = CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &dataSize)
    guard s1 == 0, dataSize > 0 else {
        print("\n=== CoreMediaIO — devices (0) ===  (query failed: \(s1))")
        return
    }
    let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
    var ids = [CMIOObjectID](repeating: 0, count: count)
    var used: UInt32 = 0
    let s2 = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, dataSize, &used, buf.baseAddress)
    }
    guard s2 == 0 else {
        print("\n=== CoreMediaIO — devices (?) ===  (fetch failed: \(s2))")
        return
    }
    label("CoreMediaIO — devices (\(count))")
    for id in ids {
        let name  = cmioString(id, UInt32(kCMIOObjectPropertyName)) ?? "?"
        let mfr   = cmioString(id, UInt32(kCMIOObjectPropertyManufacturer)) ?? "?"
        let model = cmioString(id, UInt32(kCMIODevicePropertyModelUID)) ?? "?"
        let uid   = cmioString(id, UInt32(kCMIODevicePropertyDeviceUID)) ?? "?"
        print("• \(name)")
        print("    manufacturer:  \(mfr)")
        print("    modelUID:      \(model)")
        print("    deviceUID:     \(uid)")
    }
}

// MARK: - Main

enableScreenCaptureDevices()
// Give CMIO a moment to enumerate hot-plugged / screen-capture devices.
Thread.sleep(forTimeInterval: 1.5)
avfEnumerate()
cmioEnumerate()

print("\n=== Notes ===")
print("• Look for an entry whose name/modelUID mentions \"Apple TV\" or the TV's name.")
print("• The CoreMediaIO list is the raw truth. If it appears there but not in the")
print("  AVFoundation list, the agent will use CoreMediaIO/CMIOStream directly.")
print("• If it appears NOWHERE, keep QuickTime open with the Apple TV showing and")
print("  re-run — some builds only register the device while a client is active.")
