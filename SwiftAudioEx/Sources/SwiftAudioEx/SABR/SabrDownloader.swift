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

    public init(config: SabrStreamConfig) {
        sabrStream = SabrStream(config: config)
    }

    /// Updates the streaming URL and ustreamer config on the active stream (e.g. after a reload).
    public func updateStream(serverUrl: String, ustreamerConfig: String) {
        sabrStream.set_streaming_url(url: serverUrl)
        sabrStream.set_ustreamer_config(config: ustreamerConfig)
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
        let options = SabrPlaybackOptions(enabled_track_types: EnabledTrackTypes.audio_only)
        let (_, audio_stream, selected) = try await sabrStream.start(options: options)

        let totalMs = Double(selected.audio_format.approx_duration_ms)

        try FileManager.default.createDirectory(
            at: outputPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: outputPath)

        var downloadedMs: Double = 0
        var lastProgressEmitTime: Date? = nil
        let progressInterval: TimeInterval = 0.25  // 250 ms

        for try await chunk in audio_stream {
            fileHandle.write(chunk)
            // Estimate progress: treat bytes as proportional to duration
            // (accurate enough for CBR audio; SABR sends segments with known duration)
            if totalMs > 0 {
                // Rough heuristic: bytes proportional to duration
                let estimatedFraction = Double(chunk.count) / (Double(selected.audio_format.bitrate) / 8.0 * totalMs / 1000.0)
                downloadedMs += estimatedFraction * totalMs
                let fraction = min(downloadedMs / totalMs, 0.99)
                let now = Date()
                if lastProgressEmitTime == nil || now.timeIntervalSince(lastProgressEmitTime!) >= progressInterval {
                    lastProgressEmitTime = now
                    progress(fraction)
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
