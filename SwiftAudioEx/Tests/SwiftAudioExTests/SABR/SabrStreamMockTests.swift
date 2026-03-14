import XCTest
@testable import SwiftAudioEx

/// Tests the SABR streaming pipeline using a custom mock FetchFunction.
/// Verifies that:
///  - `sabrContexts` from server updates appear in subsequent request bodies
///  - `onReloadPlayerResponse` callback fires and receives the reload token
final class SabrStreamMockTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a minimal UMP binary from (partType, partData) pairs.
    private func umpData(parts: [(type: Int, data: Data)]) -> Data {
        var result = Data()
        for (partType, partData) in parts {
            result.append(contentsOf: umpVarInt(partType))
            result.append(contentsOf: umpVarInt(partData.count))
            result.append(partData)
        }
        return result
    }

    /// UMP/YouTube varint encoding (little-endian, 6-bit groups with continuation bit).
    private func umpVarInt(_ value: Int) -> [UInt8] {
        precondition(value >= 0)
        if value < 128 {
            return [UInt8(value)]
        } else if value < 16384 {
            return [UInt8((value & 0x3F) | 0x80), UInt8(value >> 6)]
        } else {
            // 3-byte encoding, sufficient for realistic data sizes in tests
            return [
                UInt8((value & 0x1F) | 0xC0),
                UInt8((value >> 5) & 0xFF),
                UInt8(value >> 13)
            ]
        }
    }

    /// Constructs a minimal HTTPURLResponse with the given status code.
    private func httpResponse(statusCode: Int, contentType: String = "application/vnd.yt-ump") -> URLResponse {
        HTTPURLResponse(
            url: URL(string: "https://rr1.googlevideo.com/videoplayback")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": contentType]
        )!
    }

    /// Creates an audio SabrFormat suitable for format selection.
    private func audioFormat(itag: Int32 = 140, lastModified: String = "1000000") -> SabrFormat {
        var fmt = SabrFormat()
        fmt.itag = itag
        fmt.last_modified = lastModified
        fmt.mime_type = "audio/mp4; codecs=\"mp4a.40.2\""
        fmt.bitrate = 130620
        fmt.approx_duration_ms = 173280
        return fmt
    }

    /// Creates a video SabrFormat suitable for format selection.
    private func videoFormat(itag: Int32 = 243, lastModified: String = "2000000") -> SabrFormat {
        var fmt = SabrFormat()
        fmt.itag = itag
        fmt.last_modified = lastModified
        fmt.mime_type = "video/webm; codecs=\"vp9\""
        fmt.bitrate = 500000
        fmt.approx_duration_ms = 173280
        fmt.width = 640
        fmt.height = 360
        return fmt
    }

    /// Serializes a `SabrContextUpdate` proto with the given type, value, and sendByDefault flag.
    private func sabrContextUpdateData(type: Int32, value: Data, sendByDefault: Bool) throws -> Data {
        var proto = VideoStreaming_SabrContextUpdate()
        proto.type = type
        proto.value = value
        proto.sendByDefault = sendByDefault
        return try proto.serializedData()
    }

    /// Serializes a `SabrContextSendingPolicy` proto with startPolicy types.
    private func sabrContextSendingPolicyData(startPolicy: [Int32]) throws -> Data {
        var proto = VideoStreaming_SabrContextSendingPolicy()
        proto.startPolicy = startPolicy
        return try proto.serializedData()
    }

    /// Serializes a `ReloadPlaybackContext` proto with the given token.
    private func reloadPlaybackContextData(token: String) throws -> Data {
        var params = VideoStreaming_ReloadPlaybackParams()
        params.token = token
        var ctx = VideoStreaming_ReloadPlaybackContext()
        ctx.reloadPlaybackParams = params
        return try ctx.serializedData()
    }

    // MARK: - Tests

    /// Verifies that `sabrContexts` received from the server in response 1 are
    /// included in the `streamerContext` of the second outgoing request body.
    func testSabrContextsIncludedInSecondRequest() async throws {
        let contextUpdateData = try sabrContextUpdateData(type: 5, value: Data([0xCA, 0xFE]), sendByDefault: true)
        let sendingPolicyData = try sabrContextSendingPolicyData(startPolicy: [5])

        // Response 1: SabrContextUpdate + SabrContextSendingPolicy
        let response1Body = umpData(parts: [
            (type: 57, data: contextUpdateData),   // sabrContextUpdate
            (type: 59, data: sendingPolicyData),   // sabrContextSendingPolicy
        ])

        // Response 2: reloadPlayerResponse — cleanly terminates the stream
        let reloadData = try reloadPlaybackContextData(token: "test-token")
        let response2Body = umpData(parts: [
            (type: 46, data: reloadData),           // reloadPlayerResponse
        ])

        var requestBodies: [Data] = []
        let lock = NSLock()

        let mockFetch: FetchFunction = { request in
            lock.lock()
            let count = requestBodies.count
            if let body = request.httpBody { requestBodies.append(body) }
            lock.unlock()

            if count == 0 {
                return (response1Body, self.httpResponse(statusCode: 200))
            } else {
                return (response2Body, self.httpResponse(statusCode: 200))
            }
        }

        let config = SabrStreamConfig(
            server_abr_streaming_url: "https://rr1.googlevideo.com/videoplayback",
            video_playback_ustreamer_config: "dGVzdA==",
            duration_ms: 173280,
            formats: [audioFormat(), videoFormat()],
            fetch: mockFetch,
            client_name: 1,
            client_version: "2.0"
        )

        let stream = SabrStream(config: config)
        var options = SabrPlaybackOptions(enabled_track_types: EnabledTrackTypes.audio_only)
        options.stall_detection_ms = 60_000  // avoid spurious stall detection during fast test

        let (_, audio_stream, _) = try await stream.start(options: options)

        // Drain the stream — it will throw once the reload response arrives
        do {
            for try await _ in audio_stream { }
        } catch {
            // Expected: stream terminates with error after reload response
        }

        // Allow background streaming task to finish
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s

        XCTAssertGreaterThanOrEqual(requestBodies.count, 2, "Expected at least two requests to be made")

        let secondBody = try XCTUnwrap(requestBodies[safe: 1], "Second request body is missing")
        let decoded = try VideoStreaming_VideoPlaybackAbrRequest(serializedBytes: secondBody)

        XCTAssertFalse(
            decoded.streamerContext.sabrContexts.isEmpty,
            "Second request must include sabrContexts from server's first response"
        )
        XCTAssertEqual(decoded.streamerContext.sabrContexts[0].type, 5)
        XCTAssertEqual(decoded.streamerContext.sabrContexts[0].value, Data([0xCA, 0xFE]))
    }

    /// Verifies that `SabrDownloader.onReloadPlayerResponse` fires when the server
    /// returns a `reloadPlayerResponse` UMP part, and that the token is passed correctly.
    func testOnReloadPlayerResponseCallbackFires() async throws {
        let expectedToken = "reload-abc-xyz"
        let reloadData = try reloadPlaybackContextData(token: expectedToken)
        let responseBody = umpData(parts: [
            (type: 46, data: reloadData),   // reloadPlayerResponse
        ])

        let mockFetch: FetchFunction = { _ in
            return (responseBody, self.httpResponse(statusCode: 200))
        }

        let config = SabrStreamConfig(
            server_abr_streaming_url: "https://rr1.googlevideo.com/videoplayback",
            video_playback_ustreamer_config: "dGVzdA==",
            duration_ms: 173280,
            formats: [audioFormat(), videoFormat()],
            fetch: mockFetch,
            client_name: 1,
            client_version: "2.0"
        )

        var receivedToken: String? = nil
        let callbackExpectation = expectation(description: "onReloadPlayerResponse called")

        let downloader = SabrDownloader(config: config)
        downloader.onReloadPlayerResponse = { (token: String?) in
            receivedToken = token
            callbackExpectation.fulfill()
        }

        // download() will throw because the reload response terminates the stream
        do {
            _ = try await downloader.download(
                to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sabr-mock-test.m4a"),
                progress: { _ in }
            )
        } catch {
            // Expected: stream terminates with error after reload response
        }

        await fulfillment(of: [callbackExpectation], timeout: 5)
        XCTAssertEqual(receivedToken, expectedToken)
    }

    /// Verifies that the first SABR request in audio-only mode:
    ///  - Does NOT include the audio format in `selectedFormatIds` (not yet initialized)
    ///  - DOES include the video format in `selectedFormatIds` (marked for discard)
    func testFirstRequestSelectedFormatIdsInAudioOnlyMode() async throws {
        let audioFmt = audioFormat(itag: 140)
        let videoFmt = videoFormat(itag: 243)

        let reloadData = try reloadPlaybackContextData(token: "t")
        let responseBody = umpData(parts: [(type: 46, data: reloadData)])

        var capturedFirstBody: Data?

        let mockFetch: FetchFunction = { request in
            if capturedFirstBody == nil { capturedFirstBody = request.httpBody }
            return (responseBody, self.httpResponse(statusCode: 200))
        }

        let config = SabrStreamConfig(
            server_abr_streaming_url: "https://rr1.googlevideo.com/videoplayback",
            video_playback_ustreamer_config: "dGVzdA==",
            duration_ms: 173280,
            formats: [audioFmt, videoFmt],
            fetch: mockFetch,
            client_name: 1,
            client_version: "2.0"
        )

        let downloader = SabrDownloader(config: config)
        downloader.onReloadPlayerResponse = { (_: String?) in }

        do {
            _ = try await downloader.download(
                to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sabr-mock-test2.m4a"),
                progress: { _ in }
            )
        } catch { }

        let body = try XCTUnwrap(capturedFirstBody)
        let decoded = try VideoStreaming_VideoPlaybackAbrRequest(serializedBytes: body)

        // In audio-only mode the video format is the "discard" format and is always
        // present in selectedFormatIds. The audio format is absent until initialized.
        let selectedItags = decoded.selectedFormatIds.map { Int($0.itag) }
        XCTAssertTrue(selectedItags.contains(243), "Video (discard) format must be in selectedFormatIds")
        XCTAssertFalse(selectedItags.contains(140), "Audio format must NOT be in selectedFormatIds before initialization")
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
