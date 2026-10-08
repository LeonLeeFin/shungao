import Foundation
import CoreAudio

struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    var json: [String:Any] { ["id":Int(id),"uid":uid,"name":name] }
}

enum AudioInputs {
    static func string(_ id:AudioObjectID,_ selector:AudioObjectPropertySelector)->String? {
        var address=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        let value=UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity:1);value.initialize(to:nil)
        defer { value.deinitialize(count:1);value.deallocate() }
        var size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id,&address,0,nil,&size,value)==noErr else { return nil }
        return value.pointee?.takeRetainedValue() as String?
    }
    static func defaultID()->AudioDeviceID {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var value:AudioDeviceID=0;var size=UInt32(MemoryLayout<AudioDeviceID>.size)
        _=AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&value)
        return value
    }
    static func list()->[InputDevice] {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size)==noErr else { return [] }
        var ids=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&ids)==noErr else { return [] }
        return ids.compactMap { id in
            var input=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreamConfiguration,mScope:kAudioDevicePropertyScopeInput,mElement:kAudioObjectPropertyElementMain)
            var bytes:UInt32=0
            guard AudioObjectGetPropertyDataSize(id,&input,0,nil,&bytes)==noErr,bytes>0 else { return nil }
            let data=UnsafeMutableRawPointer.allocate(byteCount:Int(bytes),alignment:MemoryLayout<AudioBufferList>.alignment)
            defer { data.deallocate() }
            guard AudioObjectGetPropertyData(id,&input,0,nil,&bytes,data)==noErr else { return nil }
            let buffers=UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to:AudioBufferList.self))
            guard buffers.contains(where:{$0.mNumberChannels>0}),let uid=string(id,kAudioDevicePropertyDeviceUID),let name=string(id,kAudioObjectPropertyName) else { return nil }
            return InputDevice(id:id,uid:uid,name:name)
        }
    }
}
