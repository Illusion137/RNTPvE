import Foundation

public class SabrDownloader {
    public typealias ProgressCallback = (Double) -> Void

    private var sabrStream: SabrStream           // var — recreated on reload
    private var config: SabrStreamConfig         // mutable — updated by updateStream()

    public var onReloadPlayerResponse: ((String?) -> Void)?
    public var onRefreshPoToken: (() -> Void)?

    // Reload signalling — protected by a simple NSLock
    private let reloadLock = NSLock()
    private var reloadContinuation: CheckedContinuation<Void, Never>?

    public init(config: SabrStreamConfig) {
        self.config = config
        self.sabrStream = SabrStream(config: config)
    }

    public func updateStream(serverUrl: String, ustreamerConfig: String) {
        config.server_abr_streaming_url = serverUrl
        config.video_playback_ustreamer_config = ustreamerConfig
        // sabrStream setters are no-ops on an aborted stream but harmless
        sabrStream.set_streaming_url(url: serverUrl)
        sabrStream.set_ustreamer_config(config: ustreamerConfig)
        // Resume the waiting download loop
        reloadLock.withLock {
            reloadContinuation?.resume()
            reloadContinuation = nil
        }
    }

    public func updatePoToken(poToken: String) {
        config.po_token = poToken
        sabrStream.set_po_token(po_token: poToken)
    }

    public func download(to outputPath: URL, progress: @escaping ProgressCallback) async throws -> URL {
        var options = SabrPlaybackOptions(enabled_track_types: EnabledTrackTypes.audio_only)
        options.prefer_mp4 = true

        try FileManager.default.createDirectory(
            at: outputPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: outputPath)

        var totalBytesEstimate: Double = 0
        var downloadedBytes: Double = 0
        var lastProgressEmitTime: Date? = nil
        let progressInterval: TimeInterval = 0.25

        while true {
            // Register callbacks on whichever stream instance is current
            sabrStream.on_reload_player_response { [weak self] ctx in
                self?.onReloadPlayerResponse?(ctx.reload_playback_params?.token)
            }
            sabrStream.on_stream_protection_status_update { [weak self] status in
                if status.status == 2 { self?.onRefreshPoToken?() }
            }

            let (_, audio_stream, selected) = try await sabrStream.start(options: options)

            // Compute total bytes estimate once (use first valid result)
            if totalBytesEstimate == 0 {
                let totalMs = Double(selected.audio_format.approx_duration_ms)
                if let cl = selected.audio_format.content_length.flatMap(Double.init), cl > 0 {
                    totalBytesEstimate = cl
                } else if totalMs > 0 {
                    let br = Double(selected.audio_format.average_bitrate ?? selected.audio_format.bitrate)
                    totalBytesEstimate = br / 8.0 * totalMs / 1000.0
                }
            }

            var reloadRequested = false
            do {
                for try await chunk in audio_stream {
                    fileHandle.write(chunk)
                    if totalBytesEstimate > 0 {
                        downloadedBytes += Double(chunk.count)
                        let fraction = min(downloadedBytes / totalBytesEstimate, 0.99)
                        let now = Date()
                        if lastProgressEmitTime == nil || now.timeIntervalSince(lastProgressEmitTime!) >= progressInterval {
                            lastProgressEmitTime = now
                            progress(fraction)
                        }
                    }
                }
            } catch let error as NSError where error.domain == "SabrStream" && error.code == -2 {
                reloadRequested = true
            }

            guard reloadRequested else { break }

            // Wait up to 15 s for JS to call updateSabrStream with fresh URL/config
            let resumed = await withTaskGroup(of: Bool.self) { group in
                group.addTask { [self] in
                    await withCheckedContinuation { c in
                        reloadLock.withLock { reloadContinuation = c }
                    }
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                // If timeout won, clear any stale continuation
                if !result { reloadLock.withLock { reloadContinuation = nil } }
                return result
            }

            guard resumed else {
                try? fileHandle.close()
                throw NSError(domain: "SabrDownloader", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Reload timed out waiting for updateSabrStream"])
            }

            // Restart: truncate file and reset progress, create fresh stream
            try fileHandle.seek(toOffset: 0)
            fileHandle.truncateFile(atOffset: 0)
            downloadedBytes = 0
            lastProgressEmitTime = nil
            sabrStream = SabrStream(config: config)  // config has updated URL/ustreamerConfig
        }

        try? fileHandle.close()
        progress(1.0)
        return outputPath
    }

    public func abort() {
        sabrStream.abort()
    }
}
