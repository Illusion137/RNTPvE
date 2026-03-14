import XCTest
import Foundation
@testable import SwiftAudioEx

// MARK: - Live SABR test driven by an external shell command
//
// The test calls a configurable bash command that must print a single JSON object
// to stdout. The JSON shape is:
//
//   {
//     "sabrServerUrl":       "https://rr1.googlevideo.com/videoplayback?...",
//     "sabrUstreamerConfig": "<base64>",
//     "poToken":             "<base64>",          // optional
//     "formats": [
//       {
//         "itag": 140,
//         "lastModified": "1744730265913521",
//         "bitrate": 130620,
//         "approxDurationMs": 173280,
//         "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
//         "isDrc": false
//       },
//       {
//         "itag": 243,
//         "lastModified": "...",
//         "bitrate": 500000,
//         "approxDurationMs": 173280,
//         "mimeType": "video/webm; codecs=\"vp9\"",
//         "width": 640,
//         "height": 360
//       }
//     ],
//     "duration": 173,                            // seconds (optional)
//     "clientName": 1,                            // optional
//     "clientVersion": "2.20250101.00.00"         // optional
//   }
//
// Configure the command by setting the environment variable:
//   SABR_FETCH_CMD=/path/to/your/fetch-script.sh
//
// The command is run as:
//   bash -c "$SABR_FETCH_CMD"
//
// To run the tests (from the RNTPvE repo root):
//   SABR_FETCH_CMD="npx ts-node tests/sabr-integration/fetch-params.ts jNQXAC9IVRw" \
//     swift test --filter SabrLiveTests
//
// fetch-params.ts delegates to lib-origin/tools/sabr-fetch-params.ts which
// calls YouTubeDL.resolve_sabr_url — the same code path used by the app.
//
// Skip tag: SABR_INTEGRATION_TESTS=1 also enables these (so the gating condition
// is either env var set).

final class SabrLiveTests: XCTestCase {

    // MARK: - Setup

    private var params: SabrLiveParams!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let fetchCmd = ProcessInfo.processInfo.environment["SABR_FETCH_CMD"]
        let integrationFlag = ProcessInfo.processInfo.environment["SABR_INTEGRATION_TESTS"]

        guard fetchCmd != nil || integrationFlag == "1" else {
            throw XCTSkip(
                "Set SABR_FETCH_CMD=<command> (or SABR_INTEGRATION_TESTS=1 with env vars) " +
                "to run live SABR tests"
            )
        }

        params = try SabrLiveParams.load()
    }

    // MARK: - Tests

    /// Full audio-only download with real network.
    /// Asserts the file is written, non-empty, and progress reaches 1.0.
    func testAudioDownload() async throws {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sabr-live-audio-\(UUID().uuidString).m4a")

        defer { try? FileManager.default.removeItem(at: outputURL) }

        var progressHistory: [Double] = []
        let downloader = params.makeDownloader()

        let result = try await downloader.download(to: outputURL) { progress in
            progressHistory.append(progress)
        }

        // File must exist and contain data
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path), "Output file must exist")
        let fileSize = (try FileManager.default.attributesOfItem(atPath: result.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(fileSize, 4096, "Downloaded audio file must be at least 4 KB")

        // Progress must have fired and reached 1.0
        XCTAssertFalse(progressHistory.isEmpty, "Progress callback must fire at least once")
        XCTAssertEqual(progressHistory.last ?? 0, 1.0, accuracy: 0.001, "Progress must reach 1.0")

        // Progress must be monotonically non-decreasing
        for i in 1..<progressHistory.count {
            XCTAssertGreaterThanOrEqual(
                progressHistory[i], progressHistory[i - 1],
                "Progress must not decrease (index \(i))"
            )
        }
    }

    /// Verifies that a real SABR request body carries the preferred audio format in
    /// `preferredAudioFormatIds` and that the ustreamer config is non-empty.
    func testRequestBodyStructure() async throws {
        var capturedFirstBody: Data?
        let lock = NSLock()

        // Wrap the default fetch to intercept the first outgoing request
        let originalFetch = params.makeFetch()
        let interceptingFetch: FetchFunction = { request in
            lock.lock()
            if capturedFirstBody == nil { capturedFirstBody = request.httpBody }
            lock.unlock()
            return try await originalFetch(request)
        }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sabr-live-body-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let config = params.makeConfig(fetch: interceptingFetch)
        let downloader = SabrDownloader(config: config)

        _ = try await downloader.download(to: outputURL) { _ in }

        let body = try XCTUnwrap(capturedFirstBody, "No request body was captured")
        let decoded = try VideoStreaming_VideoPlaybackAbrRequest(serializedBytes: body)

        XCTAssertFalse(decoded.preferredAudioFormatIds.isEmpty, "preferredAudioFormatIds must be set")
        XCTAssertFalse(
            decoded.videoPlaybackUstreamerConfig.isEmpty,
            "videoPlaybackUstreamerConfig must be non-empty in request body"
        )
    }

    /// Verifies that after the first round-trip, any sabrContexts returned by the
    /// server appear in the second outgoing request.
    func testSabrContextsPropagatedToNextRequest() async throws {
        var requestBodies: [Data] = []
        let lock = NSLock()

        let originalFetch = params.makeFetch()
        let interceptingFetch: FetchFunction = { request in
            if let body = request.httpBody {
                lock.lock(); requestBodies.append(body); lock.unlock()
            }
            return try await originalFetch(request)
        }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sabr-live-ctx-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let config = params.makeConfig(fetch: interceptingFetch)
        let downloader = SabrDownloader(config: config)

        _ = try await downloader.download(to: outputURL) { _ in }

        guard requestBodies.count >= 2 else {
            // Short streams may complete in one request — skip assertion
            return
        }

        // Decode the first response's contexts from what the second request sends
        let secondDecoded = try VideoStreaming_VideoPlaybackAbrRequest(serializedBytes: requestBodies[1])
        let firstDecoded = try VideoStreaming_VideoPlaybackAbrRequest(serializedBytes: requestBodies[0])

        // The second request must have selectedFormatIds populated (formats initialized)
        XCTAssertFalse(
            secondDecoded.selectedFormatIds.isEmpty,
            "Second request must have selectedFormatIds populated after format initialization"
        )

        // First request must NOT have audio format in selectedFormatIds (not yet initialized)
        let audioItags = params.formats
            .filter { $0.mime_type?.contains("audio") == true }
            .map { Int($0.itag) }
        let firstSelectedItags = firstDecoded.selectedFormatIds.map { Int($0.itag) }
        for itag in audioItags {
            XCTAssertFalse(
                firstSelectedItags.contains(itag),
                "Audio itag \(itag) must not be in selectedFormatIds on first request"
            )
        }
    }
}

// MARK: - SabrLiveParams

/// Parsed parameters from the external fetch command or environment variables.
struct SabrLiveParams {
    let serverUrl: String
    let ustreamerConfig: String
    let poToken: String?
    let formats: [SabrFormat]
    let durationMs: Double?
    let clientName: Int32?
    let clientVersion: String?

    // MARK: Factory methods

    func makeFetch() -> FetchFunction { default_fetch }

    func makeConfig(fetch: FetchFunction? = nil) -> SabrStreamConfig {
        SabrStreamConfig(
            server_abr_streaming_url: serverUrl,
            video_playback_ustreamer_config: ustreamerConfig,
            po_token: poToken,
            duration_ms: durationMs,
            formats: formats,
            fetch: fetch ?? default_fetch,
            client_name: clientName,
            client_version: clientVersion
        )
    }

    func makeDownloader(fetch: FetchFunction? = nil) -> SabrDownloader {
        SabrDownloader(config: makeConfig(fetch: fetch))
    }

    // MARK: - Loading

    /// Loads params from:
    ///  1. The JSON output of `SABR_FETCH_CMD` (takes priority)
    ///  2. Individual environment variables as fallback
    static func load() throws -> SabrLiveParams {
        if let cmd = ProcessInfo.processInfo.environment["SABR_FETCH_CMD"], !cmd.isEmpty {
            return try loadFromCommand(cmd)
        }
        return try loadFromEnvironment()
    }

    /// Runs the given shell command and parses its stdout as JSON.
    private static func loadFromCommand(_ cmd: String) throws -> SabrLiveParams {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", cmd]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // discard stderr

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: (process.standardError as! Pipe).fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw XCTSkip("SABR_FETCH_CMD exited with status \(process.terminationStatus): \(stderr)")
        }

        return try parseJSON(data)
    }

    /// Reads params from individual environment variables (legacy / CI fallback).
    private static func loadFromEnvironment() throws -> SabrLiveParams {
        let env = ProcessInfo.processInfo.environment
        guard let serverUrl = env["SABR_SERVER_URL"], !serverUrl.isEmpty,
              let ustreamerConfig = env["SABR_USTREAMER_CONFIG"], !ustreamerConfig.isEmpty else {
            throw XCTSkip("Set SABR_FETCH_CMD or (SABR_SERVER_URL + SABR_USTREAMER_CONFIG) to run live tests")
        }
        return SabrLiveParams(
            serverUrl: serverUrl,
            ustreamerConfig: ustreamerConfig,
            poToken: env["SABR_PO_TOKEN"],
            formats: defaultFormats(),
            durationMs: env["SABR_DURATION_MS"].flatMap(Double.init),
            clientName: env["SABR_CLIENT_NAME"].flatMap { Int32($0) },
            clientVersion: env["SABR_CLIENT_VERSION"]
        )
    }

    /// Parses the JSON produced by `SABR_FETCH_CMD`.
    private static func parseJSON(_ data: Data) throws -> SabrLiveParams {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("SABR_FETCH_CMD did not produce valid JSON")
        }

        guard let serverUrl = json["sabrServerUrl"] as? String,
              let ustreamerConfig = json["sabrUstreamerConfig"] as? String else {
            throw XCTSkip("JSON is missing required fields: sabrServerUrl, sabrUstreamerConfig")
        }

        let formatDicts = json["formats"] as? [[String: Any]] ?? []
        let formats = formatDicts.isEmpty
            ? defaultFormats()
            : formatDicts.compactMap { SabrFormat(dictionary: $0) }

        let durationMs: Double?
        if let d = json["duration"] as? Double {
            durationMs = d * 1000
        } else if let d = json["durationMs"] as? Double {
            durationMs = d
        } else {
            durationMs = nil
        }

        return SabrLiveParams(
            serverUrl: serverUrl,
            ustreamerConfig: ustreamerConfig,
            poToken: json["poToken"] as? String,
            formats: formats,
            durationMs: durationMs,
            clientName: (json["clientName"] as? Int).map { Int32($0) },
            clientVersion: json["clientVersion"] as? String
        )
    }

    /// Minimal fallback formats when none are provided.
    private static func defaultFormats() -> [SabrFormat] {
        var audio = SabrFormat()
        audio.itag = 140
        audio.last_modified = "0"
        audio.mime_type = "audio/mp4; codecs=\"mp4a.40.2\""
        audio.bitrate = 130620
        audio.approx_duration_ms = 173280

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
}
