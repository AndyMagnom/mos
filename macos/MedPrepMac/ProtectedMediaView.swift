import AppKit
import AVFoundation
import CryptoKit

// Only these sample-buffer pixels are capture-protected. Arbitrary AppKit or
// WKWebView child views do not become protected by being near this layer.
@MainActor final class ProtectedMediaView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    private let logo = CALayer()
    var marker = "MedPrep"
    var didFail: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        if let url = Bundle.main.url(forResource: "app_logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            logo.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            logo.contentsGravity = .resizeAspect
        }
        // Ordinary branding remains behind excluded sample-buffer pixels.
        layer?.addSublayer(logo)
        display.preventsCapture = true
        display.videoGravity = .resizeAspect
        layer?.addSublayer(display)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func layout() {
        super.layout(); display.frame = bounds
        logo.frame = CGRect(x: bounds.midX - 60, y: bounds.midY - 50, width: 120, height: 100)
    }
    func clear() { display.flushAndRemoveImage(); layer?.contents = nil }
    func show(_ image: CGImage) {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { didFail?(); return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), let context = CGContext(data: base,
            width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { didFail?(); return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Experimental low-bit marker on owned image pixels, not a robust or
        // authenticated forensic watermark. Compression/rescaling can erase it.
        let hash = [UInt8](SHA256.hash(data: Data(marker.utf8)))
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for bit in 0..<min(256, image.width) {
            pixels[bit * 4] = (pixels[bit * 4] & 0xfe) | ((hash[bit / 8] >> (bit % 8)) & 1)
        }
        enqueue(buffer)
        layer?.contents = nil // Never draw an unprotected duplicate.
    }
    func enqueue(_ buffer: CVPixelBuffer) {
        guard display.preventsCapture else { clear(); didFail?(); return }
        if display.status == .failed { display.flushAndRemoveImage() }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &description) == noErr, let description else { didFail?(); return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { didFail?(); return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately as String] = true
        }
        if display.isReadyForMoreMediaData { display.enqueue(sample) }
    }
}
