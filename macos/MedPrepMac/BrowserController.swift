import AppKit
import WebKit

@MainActor final class BrowserController: NSViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
    private let identity = DeviceIdentity()
    private let sites = SiteRegistry()
    private var web: RestrictedWebView!
    private let cover = NSView()
    private let label = NSTextField(wrappingLabelWithString: "Verifying device…")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private let siteMenu = NSPopUpButton()
    private let watermark = WatermarkView()
    private let spinner = CubeSpinnerView(frame: .zero)
    private var splash: WKWebView?
    private var viewer: MediaViewer?
    private var verification: Task<Void, Never>?
    private var policyTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var timer: Timer?
    private var notices: [NSObjectProtocol] = []
    private var contentOrigin: URL?
    private var lastURL = AppConfig.site
    private var verifiedAt = -Double.infinity
    private var policyAttempt = -Double.infinity
    private var generation = 0
    private var verifying = false
    private var renewing = false
    private var awaitingPage = false
    private var pendingNavigation: WKNavigation?
    private var purging = false
    private var failure: String?
    private var lastIssue: String?
    private var splashFinished = false
    private var loggingOut = false
    private var previousToken: (String, URL)?
    private var mediaSuspended = false
    private var canShow: Bool {
        NSApp.isActive && view.window?.isVisible == true && view.window?.isMiniaturized != true && identity.token != nil && identity.policyCurrent &&
            CACurrentMediaTime() - verifiedAt < 300 && MacSecurityGate.issue == nil && !purging && (!verifying || renewing) && !awaitingPage && failure == nil
    }
    override func loadView() {
        view = NSView(); view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 30/255, green: 33/255, blue: 36/255, alpha: 1).cgColor
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = AppConfig.marker + " " + AppConfig.nativeMarker
        config.allowsAirPlayForMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(WKUserScript(source: Self.restrictions, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(self, name: "protectedMedia")
        web = RestrictedWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, *) { web.isInspectable = false }
        web.navigationDelegate = self; web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 12
        for (title, action) in [("Back", #selector(back)), ("Forward", #selector(forward)), ("Refresh", #selector(refresh)), ("Privacy", #selector(privacy))] {
            toolbar.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        siteMenu.target = self; siteMenu.action = #selector(switchSite); toolbar.addArrangedSubview(siteMenu)
        retry.contentTintColor = .systemOrange
        retry.target = self; retry.action = #selector(retryAccess)
        label.textColor = .white; label.font = .systemFont(ofSize: 18); label.alignment = .center
        cover.wantsLayer = true; cover.layer?.backgroundColor = NSColor.black.cgColor
        let logo = NSImageView(); logo.image = Bundle.main.url(forResource: "app_logo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        logo.imageScaling = .scaleProportionallyUpOrDown
        let card = NSStackView(views: [logo, spinner, label, retry]); card.orientation = .vertical; card.spacing = 20
        cover.addSubview(card)
        for item in [toolbar, web, watermark, cover, card] { item.translatesAutoresizingMaskIntoConstraints = false }
        for item in [toolbar, web, watermark, cover] { view.addSubview(item) }
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 12), toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            web.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12), web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            watermark.topAnchor.constraint(equalTo: web.topAnchor), watermark.bottomAnchor.constraint(equalTo: web.bottomAnchor),
            watermark.leadingAnchor.constraint(equalTo: web.leadingAnchor), watermark.trailingAnchor.constraint(equalTo: web.trailingAnchor),
            cover.topAnchor.constraint(equalTo: web.topAnchor), cover.bottomAnchor.constraint(equalTo: web.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: web.leadingAnchor), cover.trailingAnchor.constraint(equalTo: web.trailingAnchor),
            card.centerXAnchor.constraint(equalTo: cover.centerXAnchor), card.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: cover.widthAnchor, multiplier: 0.85), logo.widthAnchor.constraint(equalToConstant: 120), logo.heightAnchor.constraint(equalToConstant: 100), spinner.widthAnchor.constraint(equalToConstant: 70), spinner.heightAnchor.constraint(equalToConstant: 70)])
        updateSites()
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didChangeScreenParametersNotification, MacSecurityGate.changed] {
            notices.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in self?.lifecycle(note.name) }
            })
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            notices.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in self?.lifecycle(note.name) }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.monitor() }
        }
        showSplash()
    }
    override func viewDidAppear() {
        super.viewDidAppear(); view.window?.delegate = self
        (view.window as? ProtectedWindow)?.reapplyProtection()
        authorize(sites.start)
    }
    private func updateSites() {
        let selected = siteMenu.titleOfSelectedItem
        siteMenu.removeAllItems(); siteMenu.addItems(withTitles: Array(sites.hosts.union([AppConfig.site.host!])).sorted())
        if let selected, siteMenu.itemTitles.contains(selected) { siteMenu.selectItem(withTitle: selected) }
    }
    private func showSplash() {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "splash") else { splashFinished = true; return }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let intro = WKWebView(frame: .zero, configuration: config); intro.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(intro); splash = intro
        NSLayoutConstraint.activate([intro.topAnchor.constraint(equalTo: view.topAnchor), intro.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            intro.leadingAnchor.constraint(equalTo: view.leadingAnchor), intro.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        intro.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.3) { [weak self] in
            self?.splash?.removeFromSuperview(); self?.splash = nil; self?.splashFinished = true; self?.render()
        }
    }
    private func realm(_ url: URL) -> URL { URL(string: "https://" + (url.host?.lowercased() ?? ""))! }
    private func render() {
        let permitted = canShow
        spinner.isHidden = permitted || (!verifying && !awaitingPage)
        cover.isHidden = permitted; web.isHidden = !permitted; watermark.isHidden = !permitted
        watermark.text = identity.watermark
        label.stringValue = MacSecurityGate.issue ?? failure ?? (!NSApp.isActive ? "Content hidden while inactive." :
            (verifying ? "Verifying device access…" : (awaitingPage ? "Loading MedPrep…" : "Device verification and an approved macOS version are required.")))
        retry.isHidden = verifying || awaitingPage || !NSApp.isActive
        if !permitted { pauseWeb(); viewer?.pause() }
        else if mediaSuspended { mediaSuspended = false; web.setAllMediaPlaybackSuspended(false, completionHandler: {}) }
    }
    private func pauseWeb() {
        mediaSuspended = true
        web?.closeAllMediaPresentations(completionHandler: {})
        web?.pauseAllMediaPlayback(completionHandler: {})
        web?.setAllMediaPlaybackSuspended(true, completionHandler: {})
    }
    private func lifecycle(_ name: Notification.Name) {
        if name == NSApplication.didResignActiveNotification || name == NSWorkspace.willSleepNotification {
            verification?.cancel(); policyTask?.cancel(); mediaTask?.cancel()
            verifying = false; renewing = false
            generation += 1; identity.invalidate(); pauseWeb(); viewer?.pause()
            NSPasteboard.general.clearContents(); render(); return
        }
        MacSecurityGate.invalidate(); spinner.needsLayout = true
        monitor()
        if NSApp.isActive && identity.token == nil && !verifying && !purging && MacSecurityGate.issue == nil { authorize(lastURL) }
    }
    private func monitor() {
        guard isViewLoaded else { return }
        let issue = MacSecurityGate.issue
        if issue != nil && lastIssue == nil {
            SecurityNotices.shared.post("Protected content was hidden because a device security or display requirement was not met.")
            if let (token, origin) = previousToken { report(MacSecurityGate.issueEventType, "Local device/security/display policy withheld content; this is not proof of active recording.", token: token, origin: origin) }
            purge(); failure = issue
        }
        lastIssue = issue
        if identity.token != nil && CACurrentMediaTime() - verifiedAt >= 300 { purge(); failure = "Device verification expired." }
        if NSApp.isActive, let origin = identity.origin, policyTask == nil, CACurrentMediaTime() - policyAttempt >= 30 {
            policyAttempt = CACurrentMediaTime()
            let policyEpoch = generation; let policyToken = identity.token
            policyTask = Task { [weak self] in
                guard let self else { return }; defer { self.policyTask = nil }
                do { try await self.identity.refreshPolicy(origin: origin) }
                catch {
                    guard !Task.isCancelled, self.generation == policyEpoch, self.identity.token == policyToken else { return }
                    self.identity.invalidatePolicy(); self.purge(); self.failure = "Device or capture policy rejected this session."
                }
                guard !Task.isCancelled, self.generation == policyEpoch else { return }
                self.render()
            }
        }
        if NSApp.isActive && issue == nil && identity.token != nil && CACurrentMediaTime() - verifiedAt > 240 && !verifying { authorize(lastURL) }
        render()
    }
    private func purge() {
        guard !purging else { return }
        purging = true; generation += 1
        verification?.cancel(); policyTask?.cancel(); verifying = false; renewing = false
        mediaTask?.cancel(); viewer?.invalidate(); viewer = nil
        identity.invalidate(); previousToken = nil; contentOrigin = nil; awaitingPage = false; pendingNavigation = nil
        web.stopLoading(); pauseWeb(); NSPasteboard.general.clearContents()
        web.loadHTMLString("", baseURL: nil)
        web.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor [weak self] in self?.purging = false; self?.render() }
        }
    }
    private func authorize(_ url: URL, forceReload: Bool = false) {
        guard NSApp.isActive, !purging, MacSecurityGate.issue == nil else { render(); return }
        renewing = !forceReload && contentOrigin == realm(url) && identity.token != nil && identity.policyCurrent && failure == nil
        verification?.cancel(); verifying = true; failure = nil
        let epoch = generation; let oldOrigin = contentOrigin; let oldKey = identity.signals?.appAttestKeyID
        render()
        verification = Task { [weak self] in
            guard let self else { return }
            do {
                await self.sites.refresh(); self.updateSites()
                let target = self.sites.allows(url) ? url : self.sites.start
                let origin = self.realm(target)
                if let previousOrigin = self.identity.origin, previousOrigin != origin {
                    self.identity.invalidate(); self.identity.invalidatePolicy(); self.renewing = false; self.render()
                }
                let cookies = await self.cookies()
                try await self.identity.verify(origin: origin,
                    cookieHeader: Network.cookieHeader(cookies, for: origin.appendingPathComponent(AppConfig.identityPath)))
                try Task.checkCancellation()
                guard self.generation == epoch, NSApp.isActive, MacSecurityGate.issue == nil,
                      let token = self.identity.token else { self.verifying = false; self.identity.invalidate(); self.render(); return }
                let native = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie":
                    "MedPrepIOS=\(token); Path=/; Max-Age=300; Secure; HttpOnly; SameSite=Lax"], for: target)
                guard let cookie = native.first, cookie.isSecure, cookie.isHTTPOnly else { throw URLError(.cannotParseResponse) }
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in self.web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { c.resume() } }
                try Task.checkCancellation()
                guard self.generation == epoch, NSApp.isActive, MacSecurityGate.issue == nil else {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in self.web.configuration.websiteDataStore.httpCookieStore.delete(cookie) { c.resume() } }
                    self.verifying = false; self.identity.invalidate(); self.render(); return
                }
                let needsLoad = forceReload || oldOrigin != origin || oldKey != self.identity.signals?.appAttestKeyID || self.web.url == nil
                self.contentOrigin = origin; self.previousToken = (token, origin); self.lastURL = target
                self.verifiedAt = CACurrentMediaTime(); self.verifying = false
                if needsLoad {
                    self.awaitingPage = true; self.render()
                    self.pendingNavigation = self.web.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData))
                    if self.pendingNavigation == nil { throw URLError(.cannotLoadFromNetwork) }
                } else { self.render() }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, self.generation == epoch else { return }
                self.verifying = false; self.purge()
                self.failure = (error as? IdentityError)?.errorDescription ?? "Device verification failed. Check configuration or contact support."
                self.render()
            }
        }
    }
    private func cookies() async -> [HTTPCookie] {
        var current: [HTTPCookie] = await withCheckedContinuation { c in
            web.configuration.websiteDataStore.httpCookieStore.getAllCookies { c.resume(returning: $0) }
        }
        // Native range fetches must use the new bearer immediately, including
        // the interval before WK's asynchronous cookie update completes.
        if let token = identity.token, let origin = identity.origin {
            current.removeAll { $0.name == "MedPrepIOS" && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == origin.host }
            current += HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie":
                "MedPrepIOS=\(token); Path=/; Max-Age=300; Secure; HttpOnly; SameSite=Lax"], for: origin)
        }
        return current
    }
    @objc private func back() { if canShow { web.goBack() } }
    @objc private func forward() { if canShow { web.goForward() } }
    @objc private func refresh() { authorize(lastURL, forceReload: true) }
    @objc private func retryAccess() { authorize(lastURL, forceReload: true) }
    @objc private func privacy() { NSWorkspace.shared.open(AppConfig.privacy) }
    @objc private func switchSite() {
        if let host = siteMenu.titleOfSelectedItem, let url = URL(string: "https://" + host), sites.allows(url) { authorize(url, forceReload: true) }
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else { completionHandler(.performDefaultHandling, nil); return }
        if PinnedTrust.accepts(challenge), let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if purging && url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard NSApp.isActive, identity.token != nil, identity.policyCurrent, !purging, MacSecurityGate.issue == nil else { decisionHandler(.cancel); return }
        let main = action.targetFrame?.isMainFrame ?? true
        if sites.allows(url) {
            if main && realm(url) != contentOrigin { decisionHandler(.cancel); authorize(url, forceReload: true); return }
            if main && ["pdf", "mp4", "mov", "m4v", "m4a"].contains(url.pathExtension.lowercased()) {
                decisionHandler(.cancel); openMedia(url, kind: url.pathExtension.lowercased() == "pdf" ? "pdf" : "video"); return
            }
            if action.shouldPerformDownload { decisionHandler(.cancel); return }
            if main { lastURL = url; sites.remember(url); loggingOut = url.path == "/login/logout.php" }
            decisionHandler(.allow)
        } else if !main && sites.embedded(url) { decisionHandler(.allow) }
        else if !main && ["about", "blob", "data"].contains(url.scheme ?? "") { decisionHandler(.allow) }
        else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated && ["mailto", "tel", "sms"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard NSApp.isActive, identity.policyCurrent, MacSecurityGate.issue == nil, let url = response.response.url,
              sites.allows(url) || (!response.isForMainFrame && sites.embedded(url)) || ["about", "blob", "data"].contains(url.scheme ?? "") else { decisionHandler(.cancel); return }
        if let http = response.response as? HTTPURLResponse, [401, 403].contains(http.statusCode) { decisionHandler(.cancel); purge(); render(); return }
        if response.isForMainFrame, let mime = response.response.mimeType {
            if mime == "application/pdf" || mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") {
                decisionHandler(.cancel); openMedia(url, kind: mime == "application/pdf" ? "pdf" : (mime.hasPrefix("image/") ? "image" : "video")); return
            }
        }
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        decisionHandler(response.canShowMIMEType && !attachment ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if loggingOut { loggingOut = false; purge(); lastURL = sites.start; render(); return }
        if awaitingPage && navigation === pendingNavigation {
            awaitingPage = false; pendingNavigation = nil; render()
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        awaitingPage = false; failure = "The site could not load. Retry to reconnect."; render()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { awaitingPage = false; failure = "The page process stopped. Retry to reload."; render() }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if canShow { web.load(action.request) }; return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        alert(message, cancel: false) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        alert(message, cancel: true, completion: completionHandler)
    }
    private func alert(_ message: String, cancel: Bool, completion: @escaping (Bool) -> Void) {
        guard canShow, let window = view.window else { completion(false); return }
        let alert = NSAlert(); alert.messageText = "MedPrep"; alert.informativeText = message; alert.addButton(withTitle: "OK")
        if cancel { alert.addButton(withTitle: "Cancel") }
        alert.window.sharingType = .none
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard canShow, let window = view.window else { completionHandler(nil); return }
        let alert = NSAlert(); alert.messageText = "MedPrep"; alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        alert.accessoryView = field; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.window.sharingType = .none
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard canShow, let window = view.window else { completionHandler(nil); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.sharingType = .none
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard canShow, message.frameInfo.securityOrigin.protocol == "https",
              sites.trusts(host: message.frameInfo.securityOrigin.host),
              let body = message.body as? [String: String], let raw = body["url"], raw.count <= 4096, let url = URL(string: raw),
              sites.allows(url), ["image", "video", "pdf"].contains(body["kind"] ?? "") else { return }
        openMedia(url, kind: body["kind"]!)
    }
    private func openMedia(_ url: URL, kind: String) {
        guard canShow, sites.allows(url), realm(url) == contentOrigin, PinnedTrust.configured(host: url.host ?? "") else { return }
        let epoch = generation; mediaTask?.cancel()
        mediaTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let origin = self.identity.origin { try await self.identity.refreshPolicy(origin: origin) }
                let cookies = await self.cookies()
                try Task.checkCancellation()
                guard self.canShow, self.generation == epoch else { return }
                self.viewer?.invalidate()
                let viewer = MediaViewer(marker: self.identity.watermark, mayPlay: { [weak self] in self?.canShow == true })
                self.viewer = viewer; viewer.showWindow(nil)
                if kind == "video" { viewer.openVideo(url, cookies: { [weak self] in await self?.cookies() ?? [] }); return }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData); request.httpShouldHandleCookies = false
                request.setValue(AppConfig.marker + " " + AppConfig.nativeMarker, forHTTPHeaderField: "User-Agent")
                if let header = Network.cookieHeader(cookies, for: url) { request.setValue(header, forHTTPHeaderField: "Cookie") }
                let (bytes, response) = try await Network.session.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 20 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                    data.append(byte)
                }
                guard self.canShow, self.generation == epoch else { viewer.invalidate(); return }
                if kind == "pdf" { viewer.openPDF(data) } else { viewer.openImage(data) }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, self.generation == epoch else { return }
                self.viewer?.invalidate(); self.viewer = nil
                self.alert("Protected media could not load. Verify the site's media configuration.", cancel: false) { _ in }
            }
        }
    }
    private func report(_ type: String, _ details: String, token: String, origin: URL) {
        guard sites.allows(origin) else { return }
        Task {
            let cookies = await self.cookies(); let url = origin.appendingPathComponent(AppConfig.reportPath)
            let data = try? JSONSerialization.data(withJSONObject: ["type": type, "details": details, "device": "Native macOS", "app_version": AppConfig.version])
            guard let data else { return }
            _ = try? await Network.json(url, body: data, token: token, cookieHeader: Network.cookieHeader(cookies, for: url))
        }
    }
    func windowDidEnterFullScreen(_ notification: Notification) { (view.window as? ProtectedWindow)?.reapplyProtection() }
    func windowDidExitFullScreen(_ notification: Notification) { (view.window as? ProtectedWindow)?.reapplyProtection() }
    private static let restrictions = """
    (() => {
      const media = (url,kind) => { if(url) window.webkit.messageHandlers.protectedMedia.postMessage({url,kind}); };
      const css = document.createElement('style');
      css.textContent = '*{user-select:none!important;-webkit-user-select:none!important;-webkit-touch-callout:none!important}input,textarea,[contenteditable=true]{user-select:text!important;-webkit-user-select:text!important}';
      const prepare = () => {
        if(document.documentElement && !css.isConnected) document.documentElement.appendChild(css);
        document.querySelectorAll('input,textarea').forEach(e => { e.autocomplete='off';e.setAttribute('autocorrect','off');e.spellcheck=false; });
        document.querySelectorAll('video,audio').forEach(e => { e.pause();e.autoplay=false;e.setAttribute('playsinline',''); });
      };
      ['copy','cut','contextmenu','dragstart'].forEach(name => document.addEventListener(name,e=>e.preventDefault(),true));
      document.addEventListener('click',e=> {
        const image=e.target.closest && e.target.closest('img');
        if(image){e.preventDefault();e.stopImmediatePropagation();media(image.currentSrc || image.src,'image');}
        const video=e.target.closest && e.target.closest('video,audio');
        if(video){e.preventDefault();e.stopImmediatePropagation();media(video.currentSrc || video.src,'video');}
        const download=e.target.closest && e.target.closest('a[download]');if(download){e.preventDefault();e.stopImmediatePropagation();}
      },true);
      HTMLMediaElement.prototype.play=function(){media(this.currentSrc || this.src,'video');return Promise.reject(new Error('Use protected native playback'));};
      window.print=()=>{};
      if(navigator.share){try{Object.defineProperty(navigator,'share',{value:()=>Promise.reject(new Error('Sharing disabled'))});}catch(_){}}
      if(navigator.clipboard){['write','writeText'].forEach(k=>{try{Object.defineProperty(navigator.clipboard,k,{value:()=>Promise.reject(new Error('Copy disabled'))});}catch(_){}});}
      document.addEventListener('DOMContentLoaded',prepare);new MutationObserver(prepare).observe(document,{childList:true,subtree:true});prepare();
    })();
    """
    deinit {
        timer?.invalidate()
        for token in notices { NotificationCenter.default.removeObserver(token); NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}

@MainActor final class RestrictedWebView: WKWebView {
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), ["c", "x", "p", "s"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") { return true }
        return super.performKeyEquivalent(with: event)
    }
}
