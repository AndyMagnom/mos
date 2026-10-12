import Foundation
import AVFoundation
import UniformTypeIdentifiers

// Progressive authenticated MP4/MOV/M4A bytes only. Every range passes through
// pinned URLSession; AVFoundation never contacts an unpinned original URL.
@MainActor final class MediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let virtualURL: URL
    private let source: URL
    private let cookies: () async -> [HTTPCookie]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(source: URL, cookies: @escaping () async -> [HTTPCookie]) {
        self.source = source; self.cookies = cookies
        virtualURL = URL(string: "medprep-media://asset/content." + (["mov", "m4v", "m4a"].contains(source.pathExtension.lowercased()) ? source.pathExtension.lowercased() : "mp4"))!
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url == virtualURL else { return false }
        let key = ObjectIdentifier(request)
        tasks[key] = Task { [weak self] in
            guard let self else { request.finishLoading(with: URLError(.cancelled)); return }
            defer { self.tasks[key] = nil }
            do {
                let dataRequest = request.dataRequest
                var offset = max(0, dataRequest?.currentOffset ?? dataRequest?.requestedOffset ?? 0)
                let start = dataRequest?.requestedOffset ?? 0
                let length = Int64(dataRequest?.requestedLength ?? 1)
                guard start >= 0, length > 0, start <= Int64.max - length else { throw URLError(.badServerResponse) }
                let requestedEnd = start + length
                var total = Int64.max
                repeat {
                    try Task.checkCancellation()
                    guard !request.isCancelled else { throw URLError(.cancelled) }
                    guard offset >= 0, offset <= Int64.max - 262144 else { throw URLError(.badServerResponse) }
                    let end = min(offset + 262143, (dataRequest?.requestsAllDataToEndOfResource == true ? total : requestedEnd) - 1)
                    guard end >= offset else { break }
                    var fetch = URLRequest(url: self.source, cachePolicy: .reloadIgnoringLocalCacheData)
                    fetch.httpShouldHandleCookies = false
                    fetch.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                    fetch.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    fetch.setValue(AppConfig.marker + " " + AppConfig.nativeMarker, forHTTPHeaderField: "User-Agent")
                    if let header = Network.cookieHeader(await self.cookies(), for: self.source) { fetch.setValue(header, forHTTPHeaderField: "Cookie") }
                    let (bytes, response) = try await Network.session.bytes(for: fetch)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                          let range = http.value(forHTTPHeaderField: "Content-Range") else { throw URLError(.badServerResponse) }
                    guard let parsed = Self.parseRange(range, requestedOffset: offset, requestedEnd: end),
                          let mime = http.mimeType,
                          ["video/mp4", "video/quicktime", "audio/mp4", "audio/x-m4a"].contains(mime) else { throw URLError(.badServerResponse) }
                    total = parsed.total
                    request.contentInformationRequest?.contentType = UTType(mimeType: mime)?.identifier ?? UTType.mpeg4Movie.identifier
                    request.contentInformationRequest?.contentLength = total
                    request.contentInformationRequest?.isByteRangeAccessSupported = true
                    var data = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard data.count < 262144 else { throw URLError(.dataLengthExceedsMaximum) }
                        data.append(byte)
                    }
                    guard data.count == Int(parsed.end - offset + 1) else { throw URLError(.badServerResponse) }
                    dataRequest?.respond(with: data); offset += Int64(data.count)
                    if dataRequest == nil { break }
                } while offset < total && (dataRequest?.requestsAllDataToEndOfResource == true || offset < requestedEnd)
                try Task.checkCancellation()
                if !request.isCancelled { request.finishLoading() }
            } catch { if !request.isCancelled { request.finishLoading(with: error) } }
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
    static func parseRange(_ value: String, requestedOffset: Int64, requestedEnd: Int64) -> (end: Int64, total: Int64)? {
        guard value.range(of: "^bytes [0-9]+-[0-9]+/[0-9]+$", options: .regularExpression) != nil else { return nil }
        let numbers = value.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int64($0) }
        guard numbers.count == 3, numbers[0] == requestedOffset, numbers[1] >= requestedOffset,
              numbers[1] <= requestedEnd, numbers[2] > numbers[1] else { return nil }
        return (numbers[1], numbers[2])
    }
    func cancel() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
}
