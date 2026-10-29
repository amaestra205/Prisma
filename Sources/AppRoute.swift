import CoreAudio
import Foundation

/// Volumen compartido con el hilo de audio: [0] = objetivo, [1] = valor actual (para suavizar),
/// [2] = pico de entrada y [3] = nº de bloques procesados (solo para diagnóstico).
final class GainBox {
    let ptr: UnsafeMutablePointer<Float>
    init(_ v: Float) {
        ptr = .allocate(capacity: 4)
        ptr[0] = v
        ptr[1] = v
        ptr[2] = 0
        ptr[3] = 0
    }
    deinit { ptr.deallocate() }
    var target: Float {
        get { ptr[0] }
        set { ptr[0] = newValue }
    }
}

enum RouteError: LocalizedError {
    case tap(OSStatus), aggregate(OSStatus), ioProc(OSStatus), start(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tap(let e): return "No se pudo capturar el audio de la app (\(e.fourCC))."
        case .aggregate(let e): return "No se pudo preparar el dispositivo de salida (\(e.fourCC))."
        case .ioProc(let e), .start(let e): return "No se pudo arrancar el audio (\(e.fourCC))."
        }
    }
}

extension OSStatus {
    var fourCC: String {
        let n = UInt32(bitPattern: self)
        let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "'" + String(decoding: bytes, as: UTF8.self) + "'" }
        return String(self)
    }
}

/// Redirige el audio de un grupo de procesos (una app) a uno o varios dispositivos, aplicando un volumen.
///
/// 1. Un *process tap* intercepta el audio de la app y lo silencia en su salida original.
/// 2. Un *aggregate device* privado une ese tap con todos los dispositivos de destino.
///    El primero marca el reloj; los demás llevan compensación de deriva para no desincronizarse.
/// 3. Un IOProc copia el audio del tap a la salida de cada dispositivo multiplicado por el volumen.
final class AppRoute {
    static let uidPrefix = "io.github.amaestra205.prisma."

    let processes: Set<AudioObjectID>
    let deviceUIDs: Set<String>
    let gain: GainBox
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Índice del primer buffer de salida de cada dispositivo dentro del dispositivo agregado.
    private let outIndex: UnsafeMutablePointer<Int32>
    /// Por cada salida: [2j] = volumen propio del dispositivo, [2j+1] = ganancia aplicada ahora (para la rampa).
    private let outGain: UnsafeMutablePointer<Float>
    private var outCount = 0
    /// UID del dispositivo de cada salida, en el mismo orden que outIndex.
    private(set) var outUIDs: [String] = []

    init(name: String, processes: Set<AudioObjectID>, deviceUIDs: [String], gain: GainBox,
         deviceVolumes: [String: Float] = [:]) throws {
        self.processes = processes
        self.deviceUIDs = Set(deviceUIDs)
        self.gain = gain
        outIndex = .allocate(capacity: max(deviceUIDs.count, 1))
        outGain = .allocate(capacity: 2 * max(deviceUIDs.count, 1))
        for j in 0..<max(deviceUIDs.count, 1) {
            outGain[2 * j] = 1
            outGain[2 * j + 1] = gain.target
        }
        do { try start(name: name, uids: deviceUIDs, volumes: deviceVolumes) } catch { stop(); throw error }
    }

    deinit {
        stop()
        outIndex.deallocate()
        outGain.deallocate()
    }

    /// Cambia el volumen propio de un dispositivo sin rehacer la ruta.
    func setDeviceVolume(_ v: Float, uid: String) {
        guard let j = outUIDs.firstIndex(of: uid) else { return }
        outGain[2 * j] = v
    }

    /// El reloj principal: mejor un dispositivo con cable o integrado que uno Bluetooth.
    private static func ordered(_ uids: [String]) -> [String] {
        func isBluetooth(_ uid: String) -> Bool {
            guard let d = CA.device(forUID: uid) else { return false }
            let t = CA.value(d, kAudioDevicePropertyTransportType, default: UInt32(0))
            return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
        }
        let main = uids.first { !isBluetooth($0) } ?? uids[0]
        return [main] + uids.filter { $0 != main }
    }

    private func start(name: String, uids: [String], volumes: [String: Float]) throws {
        let devs = Self.ordered(uids)

        let desc = CATapDescription(stereoMixdownOfProcesses: processes.sorted())
        desc.name = "Prisma – \(name)"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped   // si dejamos de leer, la app vuelve a sonar normal

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { throw RouteError.tap(err) }
        tapID = tap

        let subdevices: [[String: Any]] = devs.enumerated().map { i, uid in
            [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: i == 0 ? 0 : 1]
        }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Prisma – \(name)",
            kAudioAggregateDeviceUIDKey: Self.uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: devs[0],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(config as CFDictionary, &agg)
        guard err == noErr else { throw RouteError.aggregate(err) }
        aggID = agg

        // Los buffers de salida del agregado van en el orden de sus subdispositivos.
        var next: Int32 = 0
        outCount = 0
        outUIDs = []
        for uid in devs {
            let n = CA.device(forUID: uid).map {
                CA.ids($0, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).count
            } ?? 0
            guard n > 0 else { continue }
            outIndex[outCount] = next
            outUIDs.append(uid)
            outCount += 1
            next += Int32(n)
        }
        let total = CA.ids(agg, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).count
        if outCount == 0 || Int(next) != total {   // algo no cuadra: al menos el primero
            outIndex[0] = 0
            outCount = 1
            outUIDs = [devs[0]]
        }

        for (j, uid) in outUIDs.enumerated() {
            let v = volumes[uid] ?? 1
            outGain[2 * j] = v
            outGain[2 * j + 1] = gain.target * v
        }

        let g = gain.ptr
        let idx = outIndex
        let og = outGain
        let count = outCount
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, inData, _, outData, _ in
            AppRoute.render(inData, outData, g, idx, og, count)
        }
        guard err == noErr, let proc else { throw RouteError.ioProc(err) }
        procID = proc

        Self.useOnlyTapInput(agg, proc)
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else { throw RouteError.start(err) }
        Log.d("ruta creada para \(name): \(debugInfo) → \(devs) salidas=\((0..<count).map { idx[$0] })")
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            if let p = procID {
                AudioDeviceStop(aggID, p)
                AudioDeviceDestroyIOProcID(aggID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Si algún destino tiene micrófono (p. ej. AirPods) no queremos abrirlo:
    /// eso bajaría la calidad del Bluetooth. Solo dejamos activo el último stream de entrada (el tap).
    private static func useOnlyTapInput(_ dev: AudioObjectID, _ proc: AudioDeviceIOProcID) {
        var addr = CA.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size >= 16 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return }
        let n = Int(raw.load(fromByteOffset: 8, as: UInt32.self))
        guard n > 1, 12 + 4 * n <= Int(size) else { return }
        for i in 0..<n {
            raw.storeBytes(of: UInt32(i == n - 1 ? 1 : 0), toByteOffset: 12 + 4 * i, as: UInt32.self)
        }
        _ = AudioObjectSetPropertyData(dev, &addr, 0, nil, size, raw)
    }

    /// Hilo de audio en tiempo real: sin reservas de memoria ni bloqueos.
    private static func render(_ inData: UnsafePointer<AudioBufferList>,
                               _ outData: UnsafeMutablePointer<AudioBufferList>,
                               _ g: UnsafeMutablePointer<Float>,
                               _ idx: UnsafeMutablePointer<Int32>,
                               _ og: UnsafeMutablePointer<Float>, _ count: Int) {
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        g[3] += 1

        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        var src: AudioBuffer? = nil
        for b in ins where b.mData != nil && b.mDataByteSize > 0 { src = b }   // el tap es el último
        guard let s = src, let sData = s.mData else {
            g[1] = g[0]
            return
        }
        let inCh = max(Int(s.mNumberChannels), 1)
        let inFrames = Int(s.mDataByteSize) / (4 * inCh)
        let si = sData.assumingMemoryBound(to: Float.self)
        let appTarget = g[0]

        var peak = g[2]
        for f in 0..<inFrames {
            let a = abs(si[f * inCh])
            if a > peak { peak = a }
        }

        for j in 0..<count {
            let oi = Int(idx[j])
            guard oi < outs.count, let dData = outs[oi].mData else { continue }
            let outCh = max(Int(outs[oi].mNumberChannels), 1)
            let frames = min(inFrames, Int(outs[oi].mDataByteSize) / (4 * outCh))
            guard frames > 0 else { continue }
            let di = dData.assumingMemoryBound(to: Float.self)
            let target = appTarget * og[2 * j]          // volumen de la app × volumen del dispositivo
            var cur = og[2 * j + 1]
            let step = (target - cur) / Float(frames)   // rampa para evitar chasquidos
            for f in 0..<frames {
                cur += step
                let sb = f * inCh, db = f * outCh
                for c in 0..<outCh {
                    if c < inCh { di[db + c] = si[sb + c] * cur }
                    else if inCh == 1 { di[db + c] = si[sb] * cur }
                }
            }
            og[2 * j + 1] = target
        }
        g[1] = appTarget
        g[2] = peak
    }

    /// Descripción para el diagnóstico: formato de entrada/salida del dispositivo agregado.
    var debugInfo: String {
        let ins = CA.ids(aggID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
        let outs = CA.ids(aggID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).count
        let rate = CA.value(aggID, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
        return "agg=\(aggID) tap=\(tapID) streamsIn=\(ins) streamsOut=\(outs) rate=\(Int(rate))"
    }
}
