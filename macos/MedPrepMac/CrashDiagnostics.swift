import Foundation
import MetricKit

// No signal handler, stack trace or course content is persisted. An unclean-run
// marker is a fallback, not proof of a crash (force-quit/power loss also trigger it).
final class CrashDiagnostics {
    static let shared = CrashDiagnostics()
    private var uncleanPreviousRun = false
    private let defaults = UserDefaults.standard
    func start() {
        uncleanPreviousRun = defaults.bool(forKey: "macRunUnfinished")
        defaults.set(true, forKey: "macRunUnfinished")
        if #available(macOS 26.0, *) { MacCrashSubscriber.shared.start() }
    }
    func finish() { defaults.set(false, forKey: "macRunUnfinished") }
    func takeNotice() -> String? {
        if let date = defaults.object(forKey: "previousCrashReportedAt") as? Date {
            defaults.removeObject(forKey: "previousCrashReportedAt")
            if Date().timeIntervalSince(date) < 7 * 24 * 3600 {
                uncleanPreviousRun = false
                return "macOS reported a previous MedPrep crash. If it happens again, contact support."
            }
        }
        guard uncleanPreviousRun else { return nil }
        uncleanPreviousRun = false
        return "MedPrep did not close cleanly last time. It may have crashed, been forced to quit, or lost power."
    }
}

// Xcode 26 API only. Reports can arrive after a later launch; never label the
// fallback marker as an OS-confirmed crash or intercept unsafe fatal signals.
@available(macOS 26.0, *)
private final class MacCrashSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = MacCrashSubscriber()
    func start() { MXMetricManager.shared.add(self) }
    func didReceive(_ payloads: [MXMetricPayload]) { }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where !(payload.crashDiagnostics?.isEmpty ?? true) {
            UserDefaults.standard.set(payload.timeStampEnd, forKey: "previousCrashReportedAt")
        }
    }
}
