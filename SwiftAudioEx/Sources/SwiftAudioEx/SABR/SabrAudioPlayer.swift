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

    /// Loading requests from AVPlayer that are waiting for data.
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []

    private var streamTask: Task<Void, Never>?

    // MARK: - Init

    init(stream: SabrStream) {
        self.sabrStream = stream
    }

    // MARK: - Start

    /// Begins downloading the SABR audio stream and feeding data to pending AVPlayer requests.
    /// Must be called on the main actor (same queue as the resource loader delegate).
    func start(options: SabrPlaybackOptions) {
        streamTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let (_, audio_stream, selected) = try await sabrStream.start(options: options)

                // Update UTI from the actual selected format MIME type
                let mimeType = selected.audio_format.mime_type ?? "audio/mp4"
                let uti = Self.utiForMimeType(mimeType)
                await MainActor.run { self.contentTypeUTI = uti }

                for try await chunk in audio_stream {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        self.audioData.append(chunk)
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
            // Byte range seeking is supported — we serve any offset from our buffer
            infoRequest.isByteRangeAccessSupported = true
            // Advertise actual size when known; use a large estimate while streaming
            infoRequest.contentLength = streamFinished ? Int64(audioData.count) : Int64.max
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
