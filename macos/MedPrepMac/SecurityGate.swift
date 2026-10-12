import AppKit
import Security
import Darwin
import MachO
import CoreGraphics

@MainActor enum MacSecurityGate {
    static let changed = Notification.Name("MedPrepSecurityPolicyChanged")
    private static let constants: [String]? = try? (0..<23).map { try R7.value($0) }
    private static var checkedAt = -Double.infinity
    private static var signatureCheckedAt = -Double.infinity
    private static var signatureIssue: String?
    private static var cachedIssue: String?
    private(set) static var issueEventType = "device_integrity_failed"
    static var detectVirtualMachines: Bool {
        #if DEBUG
        return UserDefaults.standard.object(forKey: "detectVirtualMachines") as? Bool ?? true
        #else
        return true
        #endif
    }
    static var allowVirtualTestDisplay: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "allowVirtualTestDisplay")
        #else
        return false
        #endif
    }
    #if DEBUG
    static func toggleVirtualDisplay() {
        UserDefaults.standard.set(!allowVirtualTestDisplay, forKey: "allowVirtualTestDisplay")
        invalidate()
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func toggleVirtualMachines() {
        UserDefaults.standard.set(!detectVirtualMachines, forKey: "detectVirtualMachines")
        invalidate()
        NotificationCenter.default.post(name: changed, object: nil)
    }
    #endif
    static func invalidate() { checkedAt = -Double.infinity }
    static var issue: String? {
        let now = ProcessInfo.processInfo.systemUptime
        if now - checkedAt < 0.5 { return cachedIssue }
        checkedAt = now
        issueEventType = "device_integrity_failed"
        cachedIssue = inspect(now: now)
        return cachedIssue
    }
    private static func inspect(now: Double) -> String? {
        guard PinnedTrust.configured(host: AppConfig.site.host ?? "") else { return "Server public-key pins are missing." }
        guard let constants else { return "Security configuration could not be decoded." }
        if let displayIssue = displayIssue(constants) { issueEventType = "external_display_detected"; return displayIssue }
        if detectVirtualMachines && isVirtualMachine(constants) { issueEventType = "vm_detected"; return "Virtual machines are blocked. Debug builds offer a testing switch in the app menu." }
        // These identify running tools, not whether they are recording. Renaming,
        // unknown tools and short-lived command-line recorders evade this heuristic.
        let recorderIDs = Set(constants[2...5])
        if NSWorkspace.shared.runningApplications.contains(where: { recorderIDs.contains($0.bundleIdentifier ?? "") }) {
            issueEventType = "capture_tool_detected"
            return "Close the recognized recording-capable application before opening protected content."
        }
        var process = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var names: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let status = names.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, u_int($0.count), &process, &size, nil, 0) }
        guard status == 0 else { return "Process integrity could not be checked." }
        if process.kp_proc.p_flag & P_TRACED != 0 { issueEventType = "debugger_detected"; return "Disconnect the debugger to continue." }
        let environment = ProcessInfo.processInfo.environment
        var injectionNames = Array(constants[6...9])
        #if DEBUG
        // Xcode sets library/framework search paths when running Debug. Library
        // validation and team-bound signatures remain mandatory in this build.
        injectionNames.removeAll { $0 == constants[7] || $0 == constants[8] }
        #endif
        if injectionNames.contains(where: { environment[$0] != nil }) { return "Injected-library environment detected." }
        for index in 0..<_dyld_image_count() {
            if let raw = _dyld_get_image_name(index) {
                let path = String(cString: raw).lowercased()
                if constants[10...14].contains(where: { path.contains($0) }) { return "Instrumentation library detected." }
            }
        }
        // Resource validation can scan the entire app. Do it on startup and
        // periodically, rather than every video frame or 0.5-second process poll.
        if now - signatureCheckedAt >= 30 {
            signatureCheckedAt = now
            signatureIssue = validateSignature(team: constants[0], identifier: constants[1])
        }
        return signatureIssue
    }
    private static func isVirtualMachine(_ constants: [String]) -> Bool {
        var present: Int32 = 0; var length = MemoryLayout<Int32>.size
        if sysctlbyname(constants[15], &present, &length, nil, 0) == 0 && present != 0 { return true }
        var count = 0
        guard sysctlbyname(constants[16], nil, &count, nil, 0) == 0, count > 0, count < 4096 else { return false }
        var bytes = [CChar](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBufferPointer { sysctlbyname(constants[16], $0.baseAddress, &count, nil, 0) }
        guard status == 0 else { return false }
        let model = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
        return constants[17...22].contains(where: { model.contains($0) })
    }
    struct DisplayState {
        let builtIn: Bool
        let mirrored: Bool
    }
    static func displayAllowed(_ displays: [DisplayState], builtInOnly: Bool) -> Bool {
        displays.count == 1 && !displays[0].mirrored && (!builtInOnly || displays[0].builtIn)
    }
    private static func displayIssue(_ constants: [String]) -> String? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 32 else { return "Display state could not be verified." }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let status = ids.withUnsafeMutableBufferPointer { CGGetOnlineDisplayList(count, $0.baseAddress, &count) }
        guard status == .success, Int(count) <= ids.count else { return "Display state could not be verified." }
        let displays = ids.prefix(Int(count)).map { DisplayState(builtIn: CGDisplayIsBuiltin($0) != 0,
            mirrored: CGDisplayIsInMirrorSet($0) != 0 || CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay) }
        guard Bundle.main.object(forInfoDictionaryKey: "MedPrepDisplayPolicy") as? String == "builtin" else { return "Built-in-only display policy is required." }
        let virtualDisplayException = allowVirtualTestDisplay && !detectVirtualMachines && isVirtualMachine(constants)
        return displayAllowed(displays, builtInOnly: !virtualDisplayException) ? nil : "Protected content requires one built-in display without mirroring. External displays are blocked."
    }
    private static func validateSignature(team: String, identifier: String) -> String? {
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              identifier.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { return "Select a valid signing team and sign the app to continue." }
        let expression = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return "Signing requirement could not be created." }
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            return "Application code signature or signing team validation failed."
        }
        var runningStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &runningStaticCode) == errSecSuccess,
              let runningStaticCode else { return "Static signing information could not be obtained." }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(runningStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let details = information as? [String: Any] else { return "Signing information could not be checked." }
        let entitlements = details[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for key in ["get-task-allow", "com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation",
                    "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.allow-unsigned-executable-memory"] {
            if (entitlements[key] as? Bool) == true { return "Unsafe signing entitlement detected." }
        }
        guard let applicationID = entitlements["com.apple.application-identifier"] as? String,
              applicationID.hasSuffix("." + identifier) else { return "Signed Keychain application identifier is missing." }
        let flags = (details[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        guard flags & 0x10000 != 0 else { return "Hardened Runtime is required." }
        var staticCode: SecStaticCode?
        let validation = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode, SecStaticCodeCheckValidity(staticCode, validation, requirement) == errSecSuccess else {
            return "Application resources or executable have been altered."
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
