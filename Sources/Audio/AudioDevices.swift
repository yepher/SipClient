import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String?
}

enum AudioDevices {
    /// List all system audio devices with at least one stream of the given direction.
    /// `input == true` for capture devices, `false` for playback devices.
    static func list(input: Bool) -> [AudioDevice] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sysObj = AudioObjectID(kAudioObjectSystemObject)

        var status = AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &ids)
        guard status == noErr else { return [] }

        var result: [AudioDevice] = []
        for id in ids {
            if !hasStreams(deviceID: id, input: input) { continue }
            let name = nameOf(deviceID: id) ?? "Device \(id)"
            let uid = uidOf(deviceID: id)
            result.append(AudioDevice(id: id, name: name, uid: uid))
        }
        return result
    }

    /// The system's current default input or output device.
    static func systemDefault(input: Bool) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: input
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &id
        )
        return status == noErr && id != 0 ? id : nil
    }

    private static func hasStreams(deviceID: AudioDeviceID, input: Bool) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: input ? kAudioDevicePropertyScopeInput
                          : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func nameOf(deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 1) { _ in
                AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
            }
        }
        guard status == noErr, let cf = name else { return nil }
        return cf as String
    }

    private static func uidOf(deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 1) { _ in
                AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
            }
        }
        guard status == noErr, let cf = uid else { return nil }
        return cf as String
    }
}
