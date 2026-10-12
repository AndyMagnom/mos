#!/usr/bin/env swift
import Foundation
import CryptoKit

// Build-time encoding only: keys must reside in the executable for local use.
// This resists a plain strings scan, not a determined reverse engineer.
let environment = ProcessInfo.processInfo.environment
let team = environment["DEVELOPMENT_TEAM"] ?? ""
let identifier = environment["PRODUCT_BUNDLE_IDENTIFIER"] ?? "com.med.prep.mac"
if environment["CONFIGURATION"] == "Release" && team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) == nil {
    fatalError("Select a valid Apple Developer team before building Release.")
}
guard CommandLine.arguments.count == 2 else { fatalError("Output Swift path required") }
let literals = [team, identifier, "com.obsproject.obs-studio", "com.apple.QuickTimePlayerX", "net.telestream.screenflow", "com.loom.desktop",
    "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_FORCE_FLAT_NAMESPACE",
    "frida", "gadget", "substrate", "libhooker", "fishhook", "kern.hv_vmm_present", "hw.model",
    "virtual", "vmware", "parallels", "qemu", "bochs", "vbox"]
let secret = SymmetricKey(size: .bits256)
let raw = secret.withUnsafeBytes { Array($0) }
let mask = SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
let hidden = zip(raw, mask).map { $0.0 ^ $0.1 }
let encrypted = try literals.map { try AES.GCM.seal(Data($0.utf8), using: secret).combined! }
let arrays = encrypted.map { "[" + $0.map { String($0) }.joined(separator: ",") + "]" }.joined(separator: ",\n")
let source = """
// Generated per build; do not ship this file or treat its embedded key as secret.
import Foundation
import CryptoKit

enum R7 {
    private static let a: [UInt8] = \(hidden)
    private static let b: [UInt8] = \(mask)
    private static let c: [[UInt8]] = [
    \(arrays)
    ]
    static func value(_ index: Int) throws -> String {
        guard c.indices.contains(index) else { throw CocoaError(.fileReadCorruptFile) }
        let key = SymmetricKey(data: Data(zip(a, b).map { $0.0 ^ $0.1 }))
        let box = try AES.GCM.SealedBox(combined: Data(c[index]))
        let bytes = try AES.GCM.open(box, using: key)
        guard let text = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return text
    }
}
"""
try source.write(toFile: CommandLine.arguments[1], atomically: false, encoding: .utf8)
