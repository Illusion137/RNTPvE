import XCTest
@testable import SwiftAudioEx

/// Real-network integration tests for SABR download.
///
/// These tests make live network requests to YouTube's SABR endpoint.
/// They are skipped by default and only run when the environment variable
/// `SABR_INTEGRATION_TESTS=1` is set.
///
/// Run with:
///   SABR_INTEGRATION_TESTS=1 swift test --filter SabrIntegration
///
/// You must supply real credentials via environment variables:
///   SABR_SERVER_URL         — deciphered serverAbrStreamingUrl
///   SABR_USTREAMER_CONFIG   — base64 videoPlaybackUstreamerConfig
///   SABR_PO_TOKEN           — (optional) proof-of-origin token
final class SabrIntegrationTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["SABR_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set SABR_INTEGRATION_TESTS=1 to run real-network SABR tests")
        }
    }

    private func makeFormats() -> [SabrFormat] {
        // itag 140 = audio/mp4 AAC 128kbps (common on most videos)
        var audio = SabrFormat()
        audio.itag = 140
        audio.last_modified = "0"
        audio.mime_type = "audio/mp4; codecs=\"mp4a.40.2\""
        audio.bitrate = 130620
        audio.approx_duration_ms = 173280

        // itag 243 = video/webm VP9 360p (common on most videos)
        var video = SabrFormat()
        video.itag = 243
        video.last_modified = "0"
        video.mime_type = "video/webm; codecs=\"vp9\""
        video.bitrate = 500000
        video.approx_duration_ms = 173280
        video.width = 640
        video.height = 360

        return [audio, video]
    }

    private func env(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw XCTSkip("Environment variable \(key) is not set")
        }
        return value
    }

    func testAudioDownloadWithRealNetwork() async throws {
        let serverUrl = try env("SABR_SERVER_URL")
        let ustreamerConfig = try env("SABR_USTREAMER_CONFIG")
        let poToken = ProcessInfo.processInfo.environment["SABR_PO_TOKEN"]

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sabr-integration-audio-\(UUID().uuidString).m4a")

        let config = SabrStreamConfig(
            server_abr_streaming_url: serverUrl,
            video_playback_ustreamer_config: ustreamerConfig,
            po_token: poToken,
            duration_ms: 173280,
            formats: makeFormats(),
            client_name: 1,
            client_version: "2.0"
        )

        let downloader = SabrDownloader(config: config)
        var progressValues: [Double] = []

        let result = try await downloader.download(to: outputURL) { progress in
            progressValues.append(progress)
        }

        // File exists and has content
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: result.path)
        let fileSize = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 1024, "Downloaded file should be at least 1KB")

        // Progress reached 1.0
        XCTAssertEqual(progressValues.last ?? 0, 1.0, accuracy: 0.001)

        // Cleanup
        try? FileManager.default.removeItem(at: outputURL)
    }
}
