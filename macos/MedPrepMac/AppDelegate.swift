import AppKit

@main @MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: NSWindowController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashDiagnostics.shared.start(); SecurityNotices.shared.start()
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About MedPrep", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Enable Security Notifications", action: #selector(enableSecurityNotifications), keyEquivalent: "").target = self
        #if DEBUG
        appMenu.addItem(withTitle: "Detect Virtual Machines (Debug)", action: #selector(toggleVirtualMachines), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Allow VM Display (Debug)", action: #selector(toggleVirtualDisplay), keyEquivalent: "").target = self
        #endif
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MedPrep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        let window = ProtectedWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.retainProtection(.course)
        window.title = "MedPrep"; window.minSize = NSSize(width: 720, height: 540)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isRestorable = false; window.isReleasedWhenClosed = false
        window.contentViewController = BrowserController()
        controller = NSWindowController(window: window)
        window.center(); controller?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.controller?.window, let notice = CrashDiagnostics.shared.takeNotice() else { return }
            let alert = NSAlert(); alert.messageText = "Previous MedPrep Session"; alert.informativeText = notice
            alert.addButton(withTitle: "OK"); alert.window.sharingType = .none
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }
    @objc private func enableSecurityNotifications() { SecurityNotices.shared.enable() }
    #if DEBUG
    @objc private func toggleVirtualMachines() { MacSecurityGate.toggleVirtualMachines() }
    @objc private func toggleVirtualDisplay() { MacSecurityGate.toggleVirtualDisplay() }
    #endif
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        #if DEBUG
        if item.action == #selector(toggleVirtualMachines) { item.state = MacSecurityGate.detectVirtualMachines ? .on : .off }
        if item.action == #selector(toggleVirtualDisplay) { item.state = MacSecurityGate.allowVirtualTestDisplay ? .on : .off }
        #endif
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { CrashDiagnostics.shared.finish() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// Reasons are per window and balanced independently. Never infer protection by
// reading sharingType: it is only a deterrent, and its getter can be stale.
@MainActor final class ProtectedWindow: NSWindow {
    enum Reason: Hashable { case course, media, dialog }
    private var reasons: [Reason: Int] = [:]
    func retainProtection(_ reason: Reason) { reasons[reason, default: 0] += 1; reapplyProtection() }
    func releaseProtection(_ reason: Reason) {
        if let count = reasons[reason], count > 1 { reasons[reason] = count - 1 }
        else { reasons.removeValue(forKey: reason) }
        reapplyProtection()
    }
    func reapplyProtection() { sharingType = reasons.isEmpty ? .readOnly : .none }
    override func becomeKey() { reapplyProtection(); super.becomeKey() }
}
