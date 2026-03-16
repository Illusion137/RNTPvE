import Foundation

/// Downloads a SABR audio stream to a local file.
///
/// The output is a fragmented MP4 (fMP4) file containing the audio track.
/// This format is directly playable by iOS/macOS without any remuxing.
public class SabrDownloader {
    public typealias ProgressCallback = (Double) -> Void  // 0.0 – 1.0

    private let sabrStream: SabrStream
    private var downloadTask: Task<URL, Error>?

    /// Called when the server requests a player response reload. Provides the reload token (may be nil).
    public var onReloadPlayerResponse: ((String?) -> Void)?

    /// Called when the server signals attestation pending (SPS=2), requesting a PoToken refresh.
    public var onRefreshPoToken: (() -> Void)?

    /// The real PoToken to silently apply on the first SPS=2 (replaces placeholder).
    public var realPoToken: String?
    private var realTokenApplied = false

    public init(config: SabrStreamConfig) {
        sabrStream = SabrStream(config: config)
    }

    /// Updates the streaming URL and ustreamer config on the active stream (e.g. after a reload).
    public func updateStream(serverUrl: String, ustreamerConfig: String) {
        sabrStream.set_streaming_url(url: serverUrl)
        sabrStream.set_ustreamer_config(config: ustreamerConfig)
    }

    /// Updates the PoToken on the active stream (e.g. after a SPS=2 attestation refresh).
    public func updatePoToken(poToken: String) {
        sabrStream.set_po_token(po_token: poToken)
    }

    /// Downloads the SABR audio stream to the given output path.
    /// - Parameters:
    ///   - outputPath: Destination file URL (should use .mp4 or .m4a extension)
    ///   - progress:   Called periodically with fraction complete (0.0 to 1.0)
    /// - Returns: The output URL on success
    public func download(to outputPath: URL, progress: @escaping ProgressCallback) async throws -> URL {
        sabrStream.on_reload_player_response { [weak self] ctx in
            self?.onReloadPlayerResponse?(ctx.reload_playback_params?.token)
        }
        sabrStream.on_stream_protection_status_update { [weak self] status in
            guard let self = self else { return }
            if status.status == 2 {
                if !self.realTokenApplied, let token = self.realPoToken {
                    // First SPS=2: silently upgrade placeholder → real token. No JS callback.
                    self.realTokenApplied = true
                    self.sabrStream.set_po_token(po_token: token)
                } else {
                    // Subsequent SPS=2 (token truly stale): ask JS to refresh.
                    self.onRefreshPoToken?()
                }
            }
        }
        var options = SabrPlaybackOptions(enabled_track_types: EnabledTrackTypes.audio_only)
        options.prefer_mp4 = true  // mp4a/AAC required for iOS AVFoundation; opus is unsupported
        let (_, audio_stream, selected) = try await sabrStream.start(options: options)

        let totalMs = Double(selected.audio_format.approx_duration_ms)

        try FileManager.default.createDirectory(
            at: outputPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: outputPath)

        var downloadedBytes: Double = 0
        var lastProgressEmitTime: Date? = nil
        let progressInterval: TimeInterval = 0.25  // 250 ms

        for try await chunk in audio_stream {
            fileHandle.write(chunk)
            if totalMs > 0 {
                // Use exact content length when available; fall back to average bitrate estimate
                let totalBytesEstimate: Double
                if let cl = selected.audio_format.content_length.flatMap(Double.init), cl > 0 {
                    totalBytesEstimate = cl
                } else {
                    let br = Double(selected.audio_format.average_bitrate ?? selected.audio_format.bitrate)
                    totalBytesEstimate = br / 8.0 * totalMs / 1000.0
                }
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
        }

        try? fileHandle.close()
        progress(1.0)
        return outputPath
    }

    public func abort() {
        sabrStream.abort()
    }
}
