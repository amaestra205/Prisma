import SwiftUI
import ServiceManagement

struct MixerView: View {
    @ObservedObject var engine: AudioEngine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Prisma").font(.headline)
                    Text("Volumen y salida para cada app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let e = engine.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Revisar permiso de audio…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            if engine.apps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("Pon algo a sonar y aparecerá aquí.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if engine.apps.count > 4 {
                ScrollView {
                    rows
                }
                .frame(height: 420)
            } else {
                rows
            }

            Divider()
            HStack {
                Toggle("Abrir al iniciar sesión", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .onChange(of: launchAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
                Spacer()
                Menu {
                    Button("Desinstalar Prisma…", role: .destructive) {
                        AppDelegate.shared.uninstall()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Más opciones")
                Button("Salir") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var rows: some View {
        VStack(spacing: 8) {
            ForEach(engine.apps) { app in
                AppRow(app: app, engine: engine)
            }
        }
    }
}

struct AppRow: View {
    let app: AudioApp
    @ObservedObject var engine: AudioEngine

    var body: some View {
        let s = engine.setting(for: app.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    if let icon = app.icon { Image(nsImage: icon).resizable() }
                    else { Image(systemName: "app.dashed").resizable() }
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(app.isPlaying ? "Sonando" : "En pausa")
                        .font(.caption2)
                        .foregroundStyle(app.isPlaying ? Color.green : Color.secondary)
                }
                Spacer(minLength: 6)

                Menu {
                    Button { engine.useSystemOutput(for: app.id) } label: {
                        if s.deviceUIDs.isEmpty { Label("Salida del sistema", systemImage: "checkmark") }
                        else { Text("Salida del sistema") }
                    }
                    Section("Puedes elegir varios a la vez") {
                        ForEach(engine.devices) { d in
                            Button { engine.toggleDevice(d.id, for: app.id) } label: {
                                if s.deviceUIDs.contains(d.id) { Label(d.name, systemImage: "checkmark") }
                                else { Text(d.name) }
                            }
                        }
                    }
                } label: {
                    Label(engine.deviceName(for: s),
                          systemImage: s.deviceUIDs.count > 1 ? "hifispeaker.2" : "hifispeaker")
                        .font(.caption)
                        .lineLimit(1)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Dispositivo por el que suena esta app")

                if !s.isDefault {
                    Button { engine.reset(app.id) } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Restablecer (volumen 100 % y salida del sistema)")
                }
            }

            HStack(spacing: 8) {
                Button { engine.toggleMute(app.id) } label: {
                    Image(systemName: speakerIcon(s))
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .help(s.muted ? "Activar sonido" : "Silenciar")

                Slider(value: Binding(get: { Double(s.muted ? 0 : s.volume) },
                                      set: { engine.setVolume(Float($0), for: app.id) }),
                       in: 0...1)
                    .controlSize(.small)

                Text("\(Int(((s.muted ? 0 : s.volume) * 100).rounded())) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            // Con varias salidas: un deslizador por dispositivo (volumen propio dentro del de la app).
            let outs = engine.connectedDevices(for: s)
            if outs.count > 1 {
                VStack(spacing: 4) {
                    ForEach(outs) { d in
                        DeviceVolumeRow(device: d,
                                        volume: engine.deviceVolume(d.id, in: s),
                                        dimmed: s.muted) { v in
                            engine.setDeviceVolume(v, device: d.id, for: app.id)
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 2)
            }
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func speakerIcon(_ s: AppSetting) -> String {
        if s.muted || s.volume < 0.001 { return "speaker.slash.fill" }
        if s.volume < 0.34 { return "speaker.wave.1.fill" }
        if s.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}


/// Volumen propio de un dispositivo cuando una app suena en varios a la vez.
struct DeviceVolumeRow: View {
    let device: OutputDevice
    let volume: Float
    let dimmed: Bool
    let onChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: device.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(device.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)
                .help(device.name)
            Slider(value: Binding(get: { Double(volume) }, set: { onChange(Float($0)) }), in: 0...1)
                .controlSize(.mini)
            Text("\(Int((volume * 100).rounded())) %")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .opacity(dimmed ? 0.45 : 1)
    }
}
