import AppKit
import ServiceManagement
import SwiftUI
import ShireCore

@main
struct ShireMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            Image(nsImage: StatusIcon.image(for: delegate.model.overall))
                .accessibilityLabel("Shire: \(delegate.model.headline)")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ShireModel()
    private lazy var window = MainWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.notifications.onOpenService = { [weak self] service in
            if let service { self?.model.selection = .service(service) }
            self?.showWindow()
        }
        model.showWindow = { [weak self] in self?.showWindow() }
        LoginItem.registerOnFirstLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppPresence.clear(model.paths)
    }

    func showWindow() {
        window.show()
    }
}

/// Starts Shire at login, so the menu bar is there whenever the services are.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Shire: couldn’t change the login item: \(error)")
        }
    }

    static func registerOnFirstLaunch() {
        let key = "registeredLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}

/// The menu bar icon: the Shire logo as a one-colour glyph with a status dot (see ShireGlyph).
enum StatusIcon {
    static func image(for overall: ShireSnapshot.Overall) -> NSImage {
        switch overall {
        case .healthy: return ShireGlyph.menuBarImage(dot: .systemGreen)
        case .attention: return ShireGlyph.menuBarImage(dot: .systemOrange)
        case .notRunning: return ShireGlyph.menuBarImage(dot: .systemGray)
        }
    }
}

/// The main window, created with AppKit so it can be opened from anywhere (the menu, a notification click).
@MainActor
final class MainWindowController {
    private let model: ShireModel
    private var window: NSWindow?

    init(model: ShireModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainWindow(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Shire"
            window.setContentSize(NSSize(width: 1100, height: 720))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("ShireMain")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
