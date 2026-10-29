import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.delegate = AppDelegate.shared
            app.setActivationPolicy(.accessory)   // solo icono en la barra de menús
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    let engine = AudioEngine()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = Self.menuBarIcon()
            b.toolTip = "Prisma"
            b.target = self
            b.action = #selector(togglePopover(_:))
        }
        let host = NSHostingController(rootView: MixerView(engine: engine))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        engine.start()

        // Si la abres tú (no al iniciar sesión), enseña el panel para que sepas dónde está.
        if !launchedAsLoginItem() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.showPopover() }
            }
        }
    }

    /// Abrir Prisma otra vez desde Aplicaciones o Spotlight muestra el panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func showPopover() {
        guard !popover.isShown, let b = statusItem.button else { return }
        engine.refresh()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stopAll()
    }

    private func launchedAsLoginItem() -> Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent else { return false }
        let oapp: AEEventID = 0x6F617070      // 'oapp'
        let prdt: AEKeyword = 0x70726474      // keyAEPropData
        let lgit: OSType = 0x6C676974         // keyAELaunchedAsLogInItem
        return ev.eventID == oapp && ev.paramDescriptor(forKeyword: prdt)?.enumCodeValue == lgit
    }

    /// Icono de la barra de menús: una fuente que se divide en tres deslizadores,
    /// como plantilla (se adapta a claro/oscuro).
    static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let node = NSPoint(x: 3.6, y: 9)
            let rows: [CGFloat] = [14.6, 9, 3.4]
            let knobs: [CGFloat] = [15.2, 12.2, 13.8]
            let split: CGFloat = 8.4, end: CGFloat = 18.4
            for (y, kx) in zip(rows, knobs) {
                let full = NSBezierPath()
                full.move(to: node)
                full.curve(to: NSPoint(x: split, y: y),
                           controlPoint1: NSPoint(x: node.x + 2.6, y: node.y),
                           controlPoint2: NSPoint(x: split - 2.4, y: y))
                full.line(to: NSPoint(x: kx, y: y))
                full.lineWidth = 1.5
                full.lineCapStyle = .round
                NSColor.black.setStroke()
                full.stroke()

                let rest = NSBezierPath()
                rest.move(to: NSPoint(x: kx, y: y))
                rest.line(to: NSPoint(x: end, y: y))
                rest.lineWidth = 1.5
                rest.lineCapStyle = .round
                NSColor.black.withAlphaComponent(0.35).setStroke()
                rest.stroke()

                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: kx - 1.9, y: y - 1.9, width: 3.8, height: 3.8)).fill()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: node.x - 2.6, y: node.y - 2.6, width: 5.2, height: 5.2)).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Prisma"
        return img
    }
}
