import AppKit
import ServiceManagement

/// Desinstalación completa desde la propia app: quita el inicio de sesión, los ajustes,
/// el permiso de audio y manda la app a la Papelera.
@MainActor
enum Uninstaller {
    static func confirmAndRun(engine: AudioEngine) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "¿Desinstalar Prisma?"
        alert.informativeText = """
            Se quitarán la app, tus ajustes de volumen y salida por app, el permiso de audio \
            y el inicio automático. Todas las apps volverán a sonar como siempre.
            """
        let ok = alert.addButton(withTitle: "Desinstalar")
        ok.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 1. Devuelve el audio de todas las apps a su salida normal.
        engine.stopAll()

        // 2. Inicio automático.
        try? SMAppService.mainApp.unregister()

        // 3. Ajustes guardados y archivos de la app en la Librería.
        let id = Bundle.main.bundleIdentifier ?? "io.github.amaestra205.prisma"
        UserDefaults.standard.removePersistentDomain(forName: id)
        UserDefaults.standard.synchronize()
        let lib = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        for path in ["Caches/\(id)", "HTTPStorages/\(id)", "Saved Application State/\(id).savedState",
                     "Preferences/\(id).plist"] {
            try? FileManager.default.removeItem(at: lib.appendingPathComponent(path))
        }

        // 4. Permiso de grabación de audio del sistema.
        let tcc = Process()
        tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tcc.arguments = ["reset", "AudioCapture", id]
        try? tcc.run()
        tcc.waitUntilExit()

        // 5. La app, a la Papelera.
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            MainActor.assumeIsolated {
                let done = NSAlert()
                if let error {
                    done.messageText = "Casi listo"
                    done.informativeText = "No se pudo mover Prisma a la Papelera (\(error.localizedDescription)). Arrástrala tú desde Aplicaciones; todo lo demás ya está borrado."
                } else {
                    done.messageText = "Prisma se ha desinstalado"
                    done.informativeText = "La app está en la Papelera y no queda nada más en tu Mac."
                }
                done.runModal()
                NSApp.terminate(nil)
            }
        }
    }
}
