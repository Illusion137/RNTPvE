import Foundation

/// Downloads a SABR audio stream to a local file.
///
/// The output is a fragmented MP4 (fMP4) file containing the audio track.
/// This format is directly playable by iOS/macOS without any remuxing.
class SabrDownloader {
    typealias ProgressCallback = (Double) -> Void  // 0.0 – 1.0

    private let sabrStream: SabrStream
    private var downloadTask: Task<URL, Error>?

    init(config: SabrStreamConfig) {
        sabrStream = SabrStream(config: config)
    }

    /// Downloads the SABR audio stream to the given output path.
    /// - Parameters:
    ///   - outputPath: Destination file URL (should use .mp4 or .m4a extension)
    ///   - progress:   Called periodically with fraction complete (0.0 to 1.0)
    /// - Returns: The output URL on success
    func download(to outputPath: URL, progress: @escaping ProgressCallback) async throws -> URL {
        let options = SabrPlaybackOptions(enabled_track_types: EnabledTrackTypes.audio_only)
        let (_, audio_stream, selected) = try await sabrStream.start(options: options)

        let totalMs = Double(selected.audio_format.approx_duration_ms)

        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: outputPath)

        var downloadedMs: Double = 0

        for try await chunk in audio_stream {
            fileHandle.write(chunk)
            // Estimate progress: treat bytes as proportional to duration
            // (accurate enough for CBR audio; SABR sends segments with known duration)
            if totalMs > 0 {
                // Rough heuristic: bytes proportional to duration
                let estimatedFraction = Double(chunk.count) / (Double(selected.audio_format.bitrate) / 8.0 * totalMs / 1000.0)
                downloadedMs += estimatedFraction * totalMs
                let fraction = min(downloadedMs / totalMs, 0.99)
                progress(fraction)
            }
        }

        try? fileHandle.close()
        progress(1.0)
        return outputPath
    }

    func abort() {
        sabrStream.abort()
    }
}
