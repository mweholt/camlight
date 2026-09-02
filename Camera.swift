import Foundation
import CoreMediaIO

// CoreMediaIO gives us `kCMIODevicePropertyDeviceIsRunningSomewhere`, which is true
// while any process on the system is pulling frames. Reading it needs no camera
// permission, so this never triggers a TCC prompt.

let systemObject = CMIOObjectID(kCMIOObjectSystemObject)

func propertyAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(selector),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(0))
}

func cameraDevices() -> [CMIOObjectID] {
    var addr = propertyAddress(kCMIOHardwarePropertyDevices)
    var dataSize: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &dataSize) == noErr else { return [] }
    let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
    guard count > 0 else { return [] }
    var ids = [CMIOObjectID](repeating: 0, count: count)
    var used: UInt32 = 0
    let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
        CMIOObjectGetPropertyData(systemObject, &addr, 0, nil, dataSize, &used, buf.baseAddress!)
    }
    return status == noErr ? ids : []
}

func stringProperty(_ device: CMIOObjectID, _ selector: Int) -> String? {
    var addr = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var used: UInt32 = 0
    let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, $0)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func cameraName(_ device: CMIOObjectID) -> String {
    stringProperty(device, kCMIOObjectPropertyName) ?? "Unknown camera"
}

func isStreaming(_ device: CMIOObjectID) -> Bool {
    var addr = propertyAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
    var value: UInt32 = 0
    var used: UInt32 = 0
    let status = CMIOObjectGetPropertyData(device, &addr, 0, nil,
                                           UInt32(MemoryLayout<UInt32>.size), &used, &value)
    return status == noErr && value != 0
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("\(stamp) camlight: \(message)")
}
