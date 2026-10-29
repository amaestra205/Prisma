import AppKit
import CoreAudio
import Combine

struct AppSetting: Codable, Equatable {
    var deviceUIDs: [String] = []   // vacío = salida del sistema; varios = suena en todos a la vez
    var deviceVolumes: [String: Float] = [:]   // volumen propio de cada dispositivo (por defecto 100 %)
    var volume: Float = 1
    var muted = false

    var isDefault: Bool { deviceUIDs.isEmpty && volume >= 0.999 && !muted }

    init() {}

    private enum CodingKeys: String, CodingKey { case deviceUIDs, deviceUID, deviceVolumes, volume, muted }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try c.decodeIfPresent([String].self, forKey: .deviceUIDs) {
            deviceUIDs = list
        } else if let one = try c.decodeIfPresent(String.self, forKey: .deviceUID) {
            deviceUIDs = [one]   // ajustes de la versión 1.0
        }
        deviceVolumes = try c.decodeIfPresent([String: Float].self, forKey: .deviceVolumes) ?? [:]
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceUIDs, forKey: .deviceUIDs)
        try c.encode(deviceVolumes, forKey: .deviceVolumes)
        try c.encode(volume, forKey: .volume)
        try c.encode(muted, forKey: .muted)
    }
}

struct AudioApp: Identifiable, Equatable {
    let id: String          // bundle ID
    let name: String
    let icon: NSImage?
    var processes: Set<AudioObjectID>
    var isPlaying: Bool

    static func == (a: AudioApp, b: AudioApp) -> Bool {
        a.id == b.id && a.name == b.name && a.processes == b.processes && a.isPlaying == b.isPlaying
    }
}

@MainActor
final class AudioEngine: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var settings: [String: AppSetting] = [:]
    @Published private(set) var errorMessage: String?

    private var routes: [String: AppRoute] = [:]
    private var gains: [String: GainBox] = [:]
    private var failedAt: [String: Date] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var timer: Timer?
    private let defaultsKey = "settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let s = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = s
        }
    }

    func start() {
        Log.d("Prisma arrancada. Dispositivos: \(CA.outputDevices().map(\.name))")
        refresh()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAll() {
        timer?.invalidate()
        for r in routes.values { r.stop() }
        routes.removeAll()
    }

    // MARK: - Lectura del estado

    func refresh() {
        let newDevices = CA.outputDevices()
        if newDevices != devices { devices = newDevices }

        let me = getpid()
        var groups: [String: AudioApp] = [:]
        for p in CA.audioProcesses() where p.pid > 0 && p.pid != me {
            guard let o = Owners.owner(of: p), o.bundleID != Bundle.main.bundleIdentifier else { continue }
            var a = groups[o.bundleID] ?? AudioApp(id: o.bundleID, name: o.name, icon: o.icon, processes: [], isPlaying: false)
            a.processes.insert(p.objectID)
            a.isPlaying = a.isPlaying || p.isPlaying
            groups[o.bundleID] = a
        }

        let now = Date()
        for a in groups.values where a.isPlaying { lastPlayed[a.id] = now }
        let visible = groups.values.filter { a in
            a.isPlaying
                || routes[a.id] != nil
                || !(settings[a.id]?.isDefault ?? true)
                || (lastPlayed[a.id].map { now.timeIntervalSince($0) < 60 } ?? false)
        }.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if visible != apps {
            apps = visible
            Log.d("apps visibles: " + visible.map { "\($0.name)[\($0.processes.count) proc\($0.isPlaying ? ", sonando" : "")]" }.joined(separator: ", "))
        }
        reconcile(running: groups)
        if Log.enabled {
            for (id, r) in routes {
                let g = r.gain.ptr
                Log.d("  \(id): bloques=\(Int(g[3])) pico=\(String(format: "%.3f", g[2])) volumen=\(g[0])")
                g[2] = 0
            }
        }
    }

    // MARK: - Cambios desde la interfaz

    func setting(for id: String) -> AppSetting { settings[id] ?? AppSetting() }

    func setVolume(_ v: Float, for id: String) {
        Log.d("volumen \(id) = \(v)")
        update(id) { $0.volume = max(0, min(1, v)); if v > 0.001 { $0.muted = false } }
    }

    func toggleMute(_ id: String) { update(id) { $0.muted.toggle() } }

    func deviceVolume(_ uid: String, in s: AppSetting) -> Float { s.deviceVolumes[uid] ?? 1 }

    func setDeviceVolume(_ v: Float, device uid: String, for id: String) {
        Log.d("volumen \(id) @ \(uid) = \(v)")
        update(id) { $0.deviceVolumes[uid] = max(0, min(1, v)) }
    }

    /// Dispositivos elegidos para una app que están conectados ahora mismo.
    func connectedDevices(for s: AppSetting) -> [OutputDevice] {
        s.deviceUIDs.compactMap { uid in devices.first { $0.id == uid } }
    }

    /// Vuelve a la salida del sistema (quita todos los dispositivos elegidos).
    func useSystemOutput(for id: String) {
        Log.d("salida \(id) = sistema")
        update(id) { $0.deviceUIDs = [] }
    }

    /// Añade o quita un dispositivo de los que usa la app.
    func toggleDevice(_ uid: String, for id: String) {
        Log.d("salida \(id) ± \(uid)")
        update(id) { s in
            if let i = s.deviceUIDs.firstIndex(of: uid) { s.deviceUIDs.remove(at: i) }
            else { s.deviceUIDs.append(uid) }
        }
    }

    func reset(_ id: String) { update(id) { $0 = AppSetting() } }

    func deviceName(for s: AppSetting) -> String {
        if s.deviceUIDs.isEmpty { return "Sistema" }
        let names = s.deviceUIDs.compactMap { uid in devices.first { $0.id == uid }?.name }
        switch names.count {
        case 0: return "No conectado"
        case 1: return names[0]
        case 2: return "\(Self.short(names[0])) + \(Self.short(names[1]))"
        default: return "\(names.count) dispositivos"
        }
    }

    /// "AirPods Pro de Alejandro" → "AirPods Pro"; "Altavoces del MacBook Air" → "Altavoces".
    private static func short(_ name: String) -> String {
        for sep in [" de ", " del "] {
            if let r = name.range(of: sep) { return String(name[..<r.lowerBound]) }
        }
        return name
    }

    private func update(_ id: String, _ change: (inout AppSetting) -> Void) {
        var s = setting(for: id)
        change(&s)
        if s.isDefault { settings[id] = nil } else { settings[id] = s }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        refresh()
    }

    // MARK: - Rutas de audio

    private func reconcile(running: [String: AudioApp]) {
        let defaultUID = CA.defaultOutputUID
        for (id, route) in routes where running[id] == nil {
            route.stop()
            routes[id] = nil
        }
        for app in running.values {
            let s = setting(for: app.id)
            let gain = gains[app.id] ?? GainBox(s.muted ? 0 : s.volume)
            gains[app.id] = gain
            gain.target = s.muted ? 0 : s.volume

            if s.isDefault {
                routes[app.id]?.stop()
                routes[app.id] = nil
                failedAt[app.id] = nil
                continue
            }
            // Solo los dispositivos conectados; si no queda ninguno, suena por la salida del sistema.
            let connected = s.deviceUIDs.filter { uid in devices.contains { $0.id == uid } }
            let uids = connected.isEmpty ? (defaultUID.map { [$0] } ?? []) : connected
            guard !uids.isEmpty else { continue }

            if let r = routes[app.id], r.processes == app.processes, r.deviceUIDs == Set(uids) {
                for uid in r.outUIDs { r.setDeviceVolume(s.deviceVolumes[uid] ?? 1, uid: uid) }
                continue
            }
            if let f = failedAt[app.id], Date().timeIntervalSince(f) < 5 { continue }

            routes[app.id]?.stop()
            routes[app.id] = nil
            do {
                routes[app.id] = try AppRoute(name: app.name, processes: app.processes, deviceUIDs: uids, gain: gain,
                                             deviceVolumes: s.deviceVolumes)
                failedAt[app.id] = nil
                if errorMessage != nil { errorMessage = nil }
            } catch {
                failedAt[app.id] = Date()
                Log.d("ERROR creando ruta para \(app.name): \(error)")
                errorMessage = "\(app.name): \(error.localizedDescription)"
            }
        }
    }
}


/// Registro de diagnóstico: solo se activa arrancando con PRISMA_DEBUG=1 desde la Terminal.
enum Log {
    static let enabled = ProcessInfo.processInfo.environment["PRISMA_DEBUG"] == "1"
    static func d(_ s: @autoclosure () -> String) {
        guard enabled else { return }
        print("[Prisma] " + s())
        fflush(stdout)
    }
}
