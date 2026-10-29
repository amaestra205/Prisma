import CoreAudio
import AppKit

/// Pequeñas utilidades para leer propiedades de Core Audio.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default def: T) -> T {
        var addr = address(sel, scope)
        var v = def
        var size = UInt32(MemoryLayout<T>.size)
        let err = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v)
        return err == noErr ? v : def
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(sel, scope)
        var ref: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        guard err == noErr, let r = ref else { return nil }
        return r.takeRetainedValue() as String
    }

    static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var list = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static var defaultOutputDevice: AudioObjectID {
        value(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    static var defaultOutputUID: String? {
        let d = defaultOutputDevice
        return d == kAudioObjectUnknown ? nil : string(d, kAudioDevicePropertyDeviceUID)
    }

    static func device(forUID uid: String) -> AudioObjectID? {
        ids(system, kAudioHardwarePropertyDevices).first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Dispositivos con salida de audio (altavoces, auriculares, pantallas…), sin los que crea esta app.
    static func outputDevices() -> [OutputDevice] {
        ids(system, kAudioHardwarePropertyDevices).compactMap { d in
            guard ids(d, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).count > 0,
                  value(d, kAudioDevicePropertyIsHidden, default: UInt32(0)) == 0,
                  let uid = string(d, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(AppRoute.uidPrefix) else { return nil }
            let name = string(d, kAudioObjectPropertyName) ?? uid
            return OutputDevice(id: uid, name: name, symbol: symbol(for: d, name: name))
        }
    }

    /// Símbolo SF según el tipo de conexión del dispositivo.
    static func symbol(for d: AudioObjectID, name: String) -> String {
        let t = value(d, kAudioDevicePropertyTransportType, default: UInt32(0))
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        default: return "hifispeaker"
        }
    }

    /// Procesos que Core Audio conoce (los que tienen o han tenido audio).
    static func audioProcesses() -> [AudioProcess] {
        ids(system, kAudioHardwarePropertyProcessObjectList).map { p in
            AudioProcess(objectID: p,
                         pid: value(p, kAudioProcessPropertyPID, default: pid_t(-1)),
                         bundleID: string(p, kAudioProcessPropertyBundleID),
                         isPlaying: value(p, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0)
        }
    }
}

struct OutputDevice: Identifiable, Hashable {
    let id: String      // UID del dispositivo
    let name: String
    let symbol: String  // icono SF Symbol
}

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool
}

/// Función del sistema que da la app "responsable" de un proceso auxiliar
/// (p. ej. Safari para su proceso WebKit, Chrome para sus helpers).
private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsibleFn: ResponsibleFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

struct AppOwner {
    let bundleID: String
    let name: String
    let icon: NSImage?
}

@MainActor
enum Owners {
    static func owner(of p: AudioProcess) -> AppOwner? {
        func visible(_ a: NSRunningApplication?) -> AppOwner? {
            guard let a, let bid = a.bundleIdentifier,
                  a.activationPolicy == .regular || a.activationPolicy == .accessory else { return nil }
            return AppOwner(bundleID: bid, name: a.localizedName ?? bid, icon: a.icon)
        }
        if let f = responsibleFn {
            let r = f(p.pid)
            if r > 0, let o = visible(NSRunningApplication(processIdentifier: r)) { return o }
        }
        if let o = visible(NSRunningApplication(processIdentifier: p.pid)) { return o }
        // Último recurso: helper cuyo bundle ID empieza por el de una app abierta.
        if let bid = p.bundleID ?? NSRunningApplication(processIdentifier: p.pid)?.bundleIdentifier {
            let parent = NSWorkspace.shared.runningApplications.first { app in
                guard app.activationPolicy == .regular, let pb = app.bundleIdentifier else { return false }
                return bid.hasPrefix(pb + ".")
            }
            if let o = visible(parent) { return o }
        }
        return nil
    }
}
