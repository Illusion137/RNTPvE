import AVFoundation
import Opus

/// Plays a YouTube SABR audio stream using the WebM/Opus pipeline.
///
/// Uses `EBMLParser` to extract Opus packets from fWebM chunks, decodes them
/// with `Opus.Decoder` (libopus via swift-opus), and schedules PCM buffers on
/// `AVAudioPlayerNode`. Stops scheduling at the exact Opus frame boundary where
/// `blockTimestampMs >= durationMs`, eliminating the silent tail that AVFoundation's
/// fMP4 pipeline cannot suppress.
///
/// Usage:
/// ```swift
/// let player = SabrOpusPlayer(stream: sabrStream)
/// player.start(options: opts, durationMs: trackDurationMs)
/// // later:
/// player.cancel()
/// ```
class SabrOpusPlayer {

    private func log(_ message: String) { print("[SabrOpusPlayer] \(message)") }

    // MARK: - Public interface (mirrors SabrAudioPlayer)

    var onRefreshPoToken: ((String) -> Void)?
    var onReloadPlayerResponse: ((String?) -> Void)?
    /// Called on the main thread once `playerNode.play()` has been invoked and audio is flowing.
    var onDidStartPlaying: (() -> Void)?
    /// Called on the main thread when the stream ends (gate fired or stream exhausted).
    var onDidFinishPlaying: (() -> Void)?
    /// Called on the main thread when playback fails with an error.
    var onDidFailPlaying: (() -> Void)?
    /// Called on the main thread immediately after AVAudioEngine starts successfully.
    var onEngineStarted: (() -> Void)?

    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()

    // MARK: - Private state

    private let sabrStream: SabrStream?
    private var streamTask: Task<Void, Never>?
    private var isCancelled = false
    private var engineStarted = false
    private var interruptionObserver: Any?
    private var engineConfigObserver: Any?

    // MARK: - Init

    init(stream: SabrStream) {
        self.sabrStream = stream
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        setupInterruptionObserver()
    }

    init() {
        self.sabrStream = nil
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        setupInterruptionObserver()
    }

    deinit {
        if let obs = interruptionObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = engineConfigObserver { NotificationCenter.default.removeObserver(obs) }
    }

    private func setupInterruptionObserver() {
        #if os(iOS) || os(tvOS) || os(watchOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in self?.handleAudioInterruption(notification) }
        #endif
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in self?.handleEngineConfigurationChange() }
    }

    private func handleEngineConfigurationChange() {
        guard !isCancelled, engineStarted else { return }
        do {
            try engine.start()
            if !playerNode.isPlaying { playerNode.play() }
        } catch {
            log("engine restart after config change failed: \(error)")
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        #if os(iOS) || os(tvOS) || os(watchOS)
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        guard !engine.isRunning else { return }
        try? engine.start()
        if !playerNode.isPlaying { playerNode.play() }
        #endif
    }

    // MARK: - Start

    func start(options: SabrPlaybackOptions, durationMs: Double = 0) {
        var opts = options
        opts.prefer_opus = true
        opts.prefer_web_m = true
        opts.prefer_mp4 = nil

        sabrStream?.on_stream_protection_status_update { [weak self] (status: StreamProtectionStatus) in
            if status.status == 2 { self?.onRefreshPoToken?("expired") }
        }
        sabrStream?.on_reload_player_response { [weak self] (ctx: ReloadPlaybackContext) in
            self?.onReloadPlayerResponse?(ctx.reload_playback_params?.token)
        }

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (_, audio_stream, _) = try await sabrStream!.start(options: opts)
                try await self.runPipeline(audioStream: audio_stream, durationMs: durationMs)
            } catch {
                guard !Task.isCancelled else { return }
                log("stream error: \(error)")
                let cb = onDidFailPlaying
                DispatchQueue.main.async { cb?() }
            }
        }
    }

    func startFile(url: URL, durationMs: Double = 0) {
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runPipeline(audioStream: makeFileStream(url: url), durationMs: durationMs)
            } catch {
                guard !Task.isCancelled else { return }
                log("file playback error: \(error)")
                let cb = onDidFailPlaying
                DispatchQueue.main.async { cb?() }
            }
        }
    }

    func cancel() {
        isCancelled = true
        engineStarted = false
        streamTask?.cancel()
        sabrStream?.abort()
        playerNode.stop()
        if engine.isRunning { engine.stop() }
    }

    func updatePoToken(_ poToken: String) {
        sabrStream?.set_po_token(po_token: poToken)
    }

    // MARK: - Pipeline

    private func runPipeline(
        audioStream: AsyncThrowingStream<Data, Error>,
        durationMs: Double
    ) async throws {
        let ebml = EBMLParser()

        var pendingPackets: [OpusPacket] = []
        var opusDecoder: Opus.Decoder?
        var pcmFormat: AVAudioFormat?
        var preSkipRemaining = 0
        engineStarted = false
        var proactiveFired = false
        var totalBytesReceived = 0

        for try await chunk in audioStream {
            guard !Task.isCancelled else { break }

            totalBytesReceived += chunk.count
            ebml.feed(chunk)

            // Trigger proactive token refresh after ~500 KB
            if !proactiveFired && totalBytesReceived >= 512_000 {
                proactiveFired = true
                onRefreshPoToken?("proactive")
            }

            // Set up decoder once we have stream info
            if opusDecoder == nil, let info = ebml.streamInfo {
                guard let formats = makeFormats(info: info) else {
                    log("failed to create audio formats")
                    let cb = onDidFailPlaying
                    DispatchQueue.main.async { cb?() }
                    return
                }
                pcmFormat = formats.pcm
                do {
                    opusDecoder = try Opus.Decoder(format: formats.pcm, application: .audio)
                } catch {
                    log("Opus.Decoder init failed: \(error)")
                    let cb = onDidFailPlaying
                    DispatchQueue.main.async { cb?() }
                    return
                }
                preSkipRemaining = info.preSkip

                // Wire engine with the real PCM format now that we know it
                engine.disconnectNodeOutput(playerNode)
                engine.connect(playerNode, to: engine.mainMixerNode, format: formats.pcm)

                if !engineStarted {
                    #if os(iOS) || os(tvOS) || os(watchOS)
                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.playback, mode: .default)
                        try session.setActive(true)
                    } catch {
                        log("AVAudioSession setup failed (non-fatal): \(error)")
                        // continue — engine.start() may still succeed
                    }
                    #endif
                    do {
                        try engine.start()
                        engineStarted = true
                        let engineCb = onEngineStarted
                        DispatchQueue.main.async { engineCb?() }
                    } catch {
                        #if os(iOS) || os(tvOS) || os(watchOS)
                        // Retry: force session active first, then try engine again
                        do {
                            try AVAudioSession.sharedInstance().setActive(true)
                            try engine.start()
                            engineStarted = true
                            let engineCb = onEngineStarted
                            DispatchQueue.main.async { engineCb?() }
                        } catch let retryError {
                            log("engine.start() failed after retry: \(retryError)")
                            let cb = onDidFailPlaying
                            DispatchQueue.main.async { cb?() }
                            return
                        }
                        #else
                        log("engine.start() failed: \(error)")
                        let cb = onDidFailPlaying
                        DispatchQueue.main.async { cb?() }
                        return
                        #endif
                    }
                }
            }

            // Flush any packets accumulated before decoder was ready
            let toProcess = pendingPackets + ebml.packets
            pendingPackets = []

            guard let dec = opusDecoder, let pcmFmt = pcmFormat else {
                // Decoder not ready yet; hold onto packets
                pendingPackets.append(contentsOf: ebml.packets)
                continue
            }

            var gate = false
            var chunkFrames: [AVAudioPCMBuffer] = []
            for packet in toProcess {
                if durationMs > 0 && packet.timestampMs >= durationMs {
                    log("gating Opus packet at \(packet.timestampMs)ms >= duration \(durationMs)ms")
                    gate = true
                    break
                }

                guard let pcmBuf = decode(
                    packet: packet,
                    decoder: dec,
                    pcmFormat: pcmFmt,
                    preSkipRemaining: &preSkipRemaining
                ) else { continue }

                chunkFrames.append(pcmBuf)
            }

            // Coalesce all decoded frames into one buffer per chunk to reduce the number of
            // scheduleBuffer() calls, which otherwise overwhelms the CoreAudio render thread.
            if let coalesced = coalescePCM(chunkFrames, format: pcmFmt) {
                playerNode.scheduleBuffer(coalesced, completionHandler: nil)
            }

            // Start playing as soon as we've scheduled the first chunk of audio —
            // don't wait for the entire stream to buffer.
            if engineStarted && !playerNode.isPlaying {
                playerNode.play()
                let cb = onDidStartPlaying
                DispatchQueue.main.async { cb?() }
            }

            if gate { break }
        }

        // Ensure playback starts even if we reach end of stream before the first play() call
        if engineStarted && !playerNode.isPlaying {
            playerNode.play()
            let cb = onDidStartPlaying
            DispatchQueue.main.async { cb?() }
        }

        // Ensure the node is playing before scheduling the sentinel, so the
        // completionCallbackType: .dataPlayedBack callback actually fires.
        if engineStarted && !playerNode.isPlaying {
            playerNode.play()
        }

        // Schedule a silent sentinel buffer so the finish callback fires only after
        // all queued PCM data has actually been played back.
        if engineStarted, let pcmFmt = pcmFormat,
           let sentinel = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: 1) {
            sentinel.frameLength = 1
            playerNode.scheduleBuffer(sentinel, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self, !self.isCancelled else { return }
                let cb = self.onDidFinishPlaying
                DispatchQueue.main.async { cb?() }
            }
        } else {
            let cb = onDidFinishPlaying
            DispatchQueue.main.async { cb?() }
        }
    }

    // MARK: - File stream

    private func makeFileStream(url: URL, chunkSize: Int = 65536) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    while true {
                        let chunk = handle.readData(ofLength: chunkSize)
                        if chunk.isEmpty { break }
                        continuation.yield(chunk)
                        try Task.checkCancellation()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - PCM coalescing

    /// Concatenates an array of PCM buffers into a single buffer.
    /// Reduces the number of `scheduleBuffer` calls, which otherwise causes CoreAudio render
    /// thread overload (`HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload`).
    private func coalescePCM(_ buffers: [AVAudioPCMBuffer], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let totalFrames = buffers.reduce(0) { $0 + AVAudioFrameCount($1.frameLength) }
        guard totalFrames > 0,
              let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            return nil
        }
        result.frameLength = totalFrames

        let channelCount = Int(format.channelCount)
        if format.isInterleaved && channelCount > 1 {
            guard let dst = result.floatChannelData?[0] else { return nil }
            var dstOffset = 0
            for buf in buffers {
                let copyCount = Int(buf.frameLength) * channelCount
                guard let src = buf.floatChannelData?[0] else { continue }
                dst.advanced(by: dstOffset).update(from: src, count: copyCount)
                dstOffset += copyCount
            }
        } else {
            var frameOffset = 0
            for buf in buffers {
                let len = Int(buf.frameLength)
                for ch in 0..<channelCount {
                    guard let src = buf.floatChannelData?[ch], let dst = result.floatChannelData?[ch] else { continue }
                    dst.advanced(by: frameOffset).update(from: src, count: len)
                }
                frameOffset += len
            }
        }
        return result
    }

    // MARK: - Opus decode

    private struct AudioFormats {
        let pcm: AVAudioFormat
    }

    private func makeFormats(info: OpusStreamInfo) -> AudioFormats? {
        // Always 48000 Hz — libopus decodes at 48kHz regardless of OpusHead sampleRate
        // swift-opus extension creates interleaved format for stereo
        guard let pcmFmt = AVAudioFormat(
            opusPCMFormat: .float32,
            sampleRate: 48000,
            channels: AVAudioChannelCount(info.channelCount)
        ) else { return nil }
        return AudioFormats(pcm: pcmFmt)
    }

    private func decode(
        packet: OpusPacket,
        decoder: Opus.Decoder,
        pcmFormat: AVAudioFormat,
        preSkipRemaining: inout Int
    ) -> AVAudioPCMBuffer? {
        let pcmBuf: AVAudioPCMBuffer
        do {
            pcmBuf = try decoder.decode(packet.data)
        } catch {
            log("Opus decode error: \(error)")
            return nil
        }

        guard preSkipRemaining > 0 else { return pcmBuf }

        let frameLen = Int(pcmBuf.frameLength)
        let skip = min(preSkipRemaining, frameLen)
        preSkipRemaining -= skip
        if skip == frameLen { return nil }

        let remaining = frameLen - skip
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(remaining)) else { return nil }
        trimmed.frameLength = AVAudioFrameCount(remaining)

        let channelCount = Int(pcmFormat.channelCount)
        if pcmFormat.isInterleaved && channelCount > 1 {
            guard let src = pcmBuf.floatChannelData?[0], let dst = trimmed.floatChannelData?[0] else { return nil }
            dst.update(from: src.advanced(by: skip * channelCount), count: remaining * channelCount)
        } else {
            for ch in 0..<channelCount {
                guard let src = pcmBuf.floatChannelData?[ch], let dst = trimmed.floatChannelData?[ch] else { continue }
                dst.update(from: src.advanced(by: skip), count: remaining)
            }
        }
        return trimmed
    }
}
