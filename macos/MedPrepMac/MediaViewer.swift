import AppKit
import AVFoundation
import ImageIO
import PDFKit

@MainActor final class MediaViewer: NSWindowController, NSWindowDelegate {
    private let media = ProtectedMediaView(frame: .zero)
    private let watermark = WatermarkView()
    private var pdf: PDFDocument?
    private var page = 0
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var loader: MediaResourceLoader?
    private var tick: Timer?
    private var loading: Task<Void, Never>?
    private let mayPlay: () -> Bool
    private let status = NSTextField(labelWithString: "Loading protected media…")
    init(marker: String, mayPlay: @escaping () -> Bool) {
        self.mayPlay = mayPlay
        let window = ProtectedWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.retainProtection(.media); window.title = "MedPrep Protected Media"; window.isRestorable = false
        super.init(window: window); window.delegate = self
        let content = NSView(); content.wantsLayer = true; content.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = content
        let controls = NSStackView(); controls.orientation = .horizontal
        controls.addArrangedSubview(NSButton(title: "Previous page", target: self, action: #selector(previousPage)))
        controls.addArrangedSubview(NSButton(title: "Next page", target: self, action: #selector(nextPage)))
        controls.addArrangedSubview(NSButton(title: "Play", target: self, action: #selector(play)))
        controls.addArrangedSubview(NSButton(title: "Pause", target: self, action: #selector(pause)))
        controls.addArrangedSubview(NSButton(title: "Back 10s", target: self, action: #selector(rewind)))
        status.textColor = .white; controls.addArrangedSubview(status)
        for view in [media, watermark, controls] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([media.topAnchor.constraint(equalTo: content.topAnchor), media.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            media.trailingAnchor.constraint(equalTo: content.trailingAnchor), media.bottomAnchor.constraint(equalTo: controls.topAnchor),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), controls.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            watermark.topAnchor.constraint(equalTo: media.topAnchor), watermark.bottomAnchor.constraint(equalTo: media.bottomAnchor),
            watermark.leadingAnchor.constraint(equalTo: media.leadingAnchor), watermark.trailingAnchor.constraint(equalTo: media.trailingAnchor)])
        watermark.text = marker; media.marker = marker
        media.didFail = { [weak self] in self?.pause(); self?.status.stringValue = "Protected rendering failed." }
    }
    required init?(coder: NSCoder) { fatalError("Use init(marker:mayPlay:)") }
    func openImage(_ data: Data) {
        guard mayPlay(), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 12000, height <= 12000, width * height <= 40_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { status.stringValue = "Image unavailable."; return }
        media.show(image); status.stringValue = "Protected image"
    }
    func openPDF(_ data: Data) {
        guard mayPlay(), let document = PDFDocument(data: data), document.pageCount > 0, document.pageCount <= 2000 else {
            status.stringValue = "Document unavailable."; return
        }
        pdf = document; page = 0; showPage()
    }
    private func showPage() {
        guard mayPlay(), let pdf, let item = pdf.page(at: page) else { media.clear(); return }
        let image = item.thumbnail(of: NSSize(width: 2048, height: 2048), for: .mediaBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { media.clear(); return }
        media.show(cg); status.stringValue = "Page \(page + 1) / \(pdf.pageCount)"
    }
    @objc private func previousPage() { page = max(0, page - 1); showPage() }
    @objc private func nextPage() { if let pdf { page = min(pdf.pageCount - 1, page + 1); showPage() } }
    func openVideo(_ url: URL, cookies: @escaping () async -> [HTTPCookie]) {
        guard mayPlay(), url.pathExtension.lowercased() != "m3u8" else {
            status.stringValue = "Protected progressive MP4/MOV/M4A required; HLS needs a controlled media pipeline."; return
        }
        let loader = MediaResourceLoader(source: url, cookies: cookies); self.loader = loader
        let asset = AVURLAsset(url: loader.virtualURL)
        asset.resourceLoader.setDelegate(loader, queue: .main)
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output); self.output = output
        player = AVPlayer(playerItem: item); player?.allowsExternalPlayback = false
        // AVPlayer has no AVPlayerLayer: video is rendered only as protected buffers.
        tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.mayPlay() || !NSApp.isActive || self.window?.isVisible != true { self.pause(); self.media.clear(); return }
                let time = output.itemTime(forHostTime: CACurrentMediaTime())
                if output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) { self.media.enqueue(buffer) }
                if item.status == .failed { self.pause(); self.media.clear(); self.status.stringValue = "Media could not be verified or decoded." }
            }
        }
        status.stringValue = "Ready — press Play. Audio capture cannot be guaranteed blocked."
    }
    @objc private func play() { guard mayPlay(), NSApp.isActive else { pause(); return }; player?.play() }
    @objc func pause() { player?.pause(); if !mayPlay() || !NSApp.isActive { media.clear() } }
    @objc private func rewind() {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, player.currentTime().seconds - 10), preferredTimescale: 600))
    }
    func invalidate() { pause(); loading?.cancel(); tick?.invalidate(); tick = nil; loader?.cancel(); player = nil; media.clear(); close() }
    func windowWillClose(_ notification: Notification) { pause(); tick?.invalidate(); loader?.cancel(); loader = nil; player = nil; output = nil; pdf = nil; media.clear() }
    func windowDidEnterFullScreen(_ notification: Notification) { (window as? ProtectedWindow)?.reapplyProtection() }
    func windowDidExitFullScreen(_ notification: Notification) { (window as? ProtectedWindow)?.reapplyProtection() }
}
