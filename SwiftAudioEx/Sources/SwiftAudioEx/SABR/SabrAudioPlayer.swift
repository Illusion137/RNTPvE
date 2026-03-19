import Foundation
import AVFoundation

/// Bridges SabrStream's audio output to AVPlayer via AVAssetResourceLoader.
///
/// Usage:
/// 1. Create SabrAudioPlayer(stream:)
/// 2. Call start(options:) to begin SABR download
/// 3. Create AVURLAsset(url: SabrAudioPlayer.assetURL)
/// 4. Set resourceLoader.setDelegate(player, queue: .main) on the asset
/// 5. Create AVPlayerItem(asset:) and give it to AVPlayer
class SabrAudioPlayer: NSObject, AVAssetResourceLoaderDelegate {

    // MARK: - Constants

    static let customScheme = "sabr-audio"

    /// Use this URL for the AVURLAsset to trigger the resource loader.
    static let assetURL = URL(string: "\(customScheme)://stream")!

    // MARK: - State

    private let sabrStream: SabrStream

    /// Accumulated audio data from the SABR stream.
    private var audioData = Data()

    /// True once the SABR stream has finished (no more chunks coming).
    private var streamFinished = false

    /// Content type UTI for the audio. Defaults to M4A; updated once format is known.
    private var contentTypeUTI: String = "com.apple.m4a-audio"

    /// Estimated content length derived from format metadata.
    private var estimatedContentLength: Int64 = 0

    /// Loading requests from AVPlayer that are waiting for data.
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []

    private var streamTask: Task<Void, Never>?

    var onRefreshPoToken: ((String) -> Void)?
    var onReloadPlayerResponse: ((String?) -> Void)?

    // MARK: - Init

    init(stream: SabrStream) {
        self.sabrStream = stream
    }

    // MARK: - Start

    /// Begins downloading the SABR audio stream and feeding data to pending AVPlayer requests.
    /// Must be called on the main actor (same queue as the resource loader delegate).
    func start(options: SabrPlaybackOptions) {
        var opts = options
        opts.prefer_mp4 = true

        sabrStream.on_stream_protection_status_update { [weak self] status in
            if status.status == 2 { self?.onRefreshPoToken?("expired") }
        }
        sabrStream.on_reload_player_response { [weak self] ctx in
            self?.onReloadPlayerResponse?(ctx.reload_playback_params?.token)
        }

        streamTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let (_, audio_stream, selected) = try await sabrStream.start(options: opts)

                // Update UTI from the actual selected format MIME type
                let mimeType = selected.audio_format.mime_type ?? "audio/mp4"
                let uti = Self.utiForMimeType(mimeType)

                // Compute estimated content length
                let fmt = selected.audio_format
                let cl: Int64
                if let s = fmt.content_length, let v = Int64(s), v > 0 { cl = v }
                else {
                    let ms = Double(fmt.approx_duration_ms)
                    let br = Double(fmt.average_bitrate ?? fmt.bitrate)
                    cl = (ms > 0 && br > 0) ? Int64(br / 8.0 * ms / 1000.0) : 0
                }

                await MainActor.run {
                    self.contentTypeUTI = uti
                    self.estimatedContentLength = cl
                }

                var initFixed = false
                var proactiveFired = false
                for try await chunk in audio_stream {
                    guard !Task.isCancelled else { break }
                    let chunkToAppend = initFixed ? chunk : { initFixed = true; return fixMP4InitSegment(chunk, durationMs: Double(fmt.approx_duration_ms)) }()
                    await MainActor.run {
                        self.audioData.append(chunkToAppend)
                        if !proactiveFired && self.audioData.count >= 512_000 {
                            proactiveFired = true
                            self.onRefreshPoToken?("proactive")
                        }
                        self.processPendingRequests()
                    }
                }

                await MainActor.run {
                    self.streamFinished = true
                    self.processPendingRequests()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.streamFinished = true
                    for request in self.pendingRequests {
                        request.finishLoading(with: error)
                    }
                    self.pendingRequests.removeAll()
                }
            }
        }
    }

    func updatePoToken(_ poToken: String) {
        sabrStream.set_po_token(po_token: poToken)
    }

    // MARK: - Cancellation

    func cancel() {
        streamTask?.cancel()
        sabrStream.abort()
        let err = CancellationError()
        for request in pendingRequests {
            request.finishLoading(with: err)
        }
        pendingRequests.removeAll()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        pendingRequests.append(loadingRequest)
        processPendingRequests()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        pendingRequests.removeAll { $0 === loadingRequest }
    }

    // MARK: - Request fulfillment

    private func processPendingRequests() {
        pendingRequests = pendingRequests.filter { !tryFulfillRequest($0) }
    }

    /// Attempts to fulfill as much of `request` as currently available.
    /// Returns true if the request was completely satisfied and removed from the queue.
    private func tryFulfillRequest(_ request: AVAssetResourceLoadingRequest) -> Bool {
        // Fill content info (required by AVPlayer before it knows what to do with the asset)
        if let infoRequest = request.contentInformationRequest {
            infoRequest.contentType = contentTypeUTI
            // Sequential stream — byte-range access disabled to prevent AVPlayer from
            // issuing random-access probes (e.g. seek to end for duration) that can
            // never be satisfied, which was causing AVPlayer to stall indefinitely.
            infoRequest.isByteRangeAccessSupported = false
            infoRequest.contentLength = streamFinished
                ? Int64(audioData.count)
                : (estimatedContentLength > 0 ? estimatedContentLength : Int64(audioData.count))
        }

        guard let dataRequest = request.dataRequest else {
            // Content info only request — satisfied
            request.finishLoading()
            return true
        }

        let currentOffset = dataRequest.currentOffset
        let available = Int64(audioData.count)

        // Not enough data yet at the requested position
        if available <= currentOffset {
            if streamFinished {
                request.finishLoading()
                return true
            }
            return false
        }

        // Respond with however much data we currently have
        let start = Int(currentOffset)
        let end: Int
        if dataRequest.requestsAllDataToEndOfResource {
            end = audioData.count
        } else {
            let wantedEnd = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
            end = min(wantedEnd, audioData.count)
        }

        if end > start {
            dataRequest.respond(with: audioData[start..<end])
        }

        // Determine if the request is now fully satisfied
        let satisfied: Bool
        if dataRequest.requestsAllDataToEndOfResource {
            satisfied = streamFinished
        } else {
            let wantedEnd = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
            satisfied = audioData.count >= wantedEnd
        }

        if satisfied {
            request.finishLoading()
            return true
        }

        return false
    }

    // MARK: - MIME → UTI

    private static func utiForMimeType(_ mimeType: String) -> String {
        let lower = mimeType.lowercased()
        if lower.contains("webm") { return "org.webmproject.webm" }
        if lower.contains("mp4") || lower.contains("m4a") || lower.contains("aac") {
            return "com.apple.m4a-audio"
        }
        if lower.contains("ogg") || lower.contains("opus") { return "public.ogg-vorbis" }
        return "public.audio"
    }
}
