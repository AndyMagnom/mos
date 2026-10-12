import AppKit
import Security
import Darwin
import MachO

@MainActor enum MacSecurityGate {
    // These identify running tools, not whether they are recording. Renaming,
    // unknown tools and short-lived command-line recorders evade this heuristic.
    private static let recorderIDs: Set<String> = ["com.obsproject.obs-studio", "com.apple.QuickTimePlayerX",
        "net.telestream.screenflow", "com.loom.desktop"]
    private static var checkedAt = -Double.infinity
    private static var cachedIssue: String?
    static var issue: String? {
        let now = ProcessInfo.processInfo.systemUptime
        if now - checkedAt < 0.5 { return cachedIssue }
        checkedAt = now
        cachedIssue = inspect()
        return cachedIssue
    }
    private static func inspect() -> String? {
        guard PinnedTrust.configured(host: AppConfig.site.host ?? "") else { return "Server public-key pins are missing." }
        if NSWorkspace.shared.runningApplications.contains(where: { recorderIDs.contains($0.bundleIdentifier ?? "") }) {
            return "Close the recognized recording-capable application before opening protected content."
        }
        var process = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var names: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let status = names.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, u_int($0.count), &process, &size, nil, 0) }
        guard status == 0 else { return "Process integrity could not be checked." }
        if process.kp_proc.p_flag & P_TRACED != 0 { return "Disconnect the debugger to continue." }
        if ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] != nil { return "Injected-library environment detected." }
        for index in 0..<_dyld_image_count() {
            if let raw = _dyld_get_image_name(index), String(cString: raw).lowercased().contains("frida") {
                return "Instrumentation library detected."
            }
        }
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return "Application code signature validation failed."
        }
        return nil
    }
}

@MainActor final class WatermarkView: NSView {
    var text = "MedPrep — device verification required" { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.28)]
        let label = text + " / " + ISO8601DateFormatter().string(from: Date())
        for y in stride(from: CGFloat(30), to: bounds.height, by: CGFloat(170)) {
            for x in stride(from: CGFloat(20), to: bounds.width, by: CGFloat(360)) {
                label.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            }
        }
    }
}
