import AVFoundation

/// Plays a YouTube SABR audio stream using the WebM/Opus pipeline.
///
/// Uses `EBMLParser` to extract Opus packets from fWebM chunks, decodes them
/// with `AVAudioConverter` (AudioToolbox Opus, iOS 13+), and schedules PCM
/// buffers on `AVAudioPlayerNode`. Stops scheduling at the exact Opus frame
/// boundary where `blockTimestampMs >= durationMs`, eliminating the silent
/// tail that AVFoundation's fMP4 pipeline cannot suppress.
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
                let cb = onDidFinishPlaying
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

        // We need stream info before we can set up the converter.
        // Collect packets until we have it.
        var pendingPackets: [OpusPacket] = []
        var converter: AVAudioConverter?
        var pcmFormat: AVAudioFormat?
        var opusFormat: AVAudioFormat?
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

            // Set up converter once we have stream info
            if converter == nil, let info = ebml.streamInfo {
                guard let formats = makeFormats(info: info) else {
                    log("failed to create audio formats")
                    return
                }
                opusFormat = formats.opus
                pcmFormat = formats.pcm
                guard let conv = AVAudioConverter(from: formats.opus, to: formats.pcm) else {
                    log("AVAudioConverter init failed (kAudioFormatOpus unavailable?)")
                    return
                }
                converter = conv
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
                            let cb = onDidFinishPlaying
                            DispatchQueue.main.async { cb?() }
                            return
                        }
                        #else
                        log("engine.start() failed: \(error)")
                        let cb = onDidFinishPlaying
                        DispatchQueue.main.async { cb?() }
                        return
                        #endif
                    }
                }
            }

            // Flush any packets accumulated before converter was ready
            let toProcess = pendingPackets + ebml.packets
            pendingPackets = []

            guard let conv = converter,
                  let pcmFmt = pcmFormat,
                  let opusFmt = opusFormat else {
                // Converter not ready yet; hold onto packets
                pendingPackets.append(contentsOf: ebml.packets)
                continue
            }

            var gate = false
            for packet in toProcess {
                if durationMs > 0 && packet.timestampMs >= durationMs {
                    log("gating Opus packet at \(packet.timestampMs)ms >= duration \(durationMs)ms")
                    gate = true
                    break
                }

                guard let pcmBuf = decode(
                    packet: packet,
                    converter: conv,
                    opusFormat: opusFmt,
                    pcmFormat: pcmFmt,
                    preSkipRemaining: &preSkipRemaining
                ) else { continue }

                playerNode.scheduleBuffer(pcmBuf, completionHandler: nil)
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

    // MARK: - Opus decode

    private struct AudioFormats {
        let opus: AVAudioFormat
        let pcm: AVAudioFormat
    }

    private func makeFormats(info: OpusStreamInfo) -> AudioFormats? {
        var opusDesc = AudioStreamBasicDescription(
            mSampleRate: info.sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(info.channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let opusFmt = AVAudioFormat(streamDescription: &opusDesc) else { return nil }
        guard let pcmFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: info.sampleRate,
            channels: AVAudioChannelCount(info.channelCount),
            interleaved: false
        ) else { return nil }
        return AudioFormats(opus: opusFmt, pcm: pcmFmt)
    }

    private func decode(
        packet: OpusPacket,
        converter: AVAudioConverter,
        opusFormat: AVAudioFormat,
        pcmFormat: AVAudioFormat,
        preSkipRemaining: inout Int
    ) -> AVAudioPCMBuffer? {
        let compressed = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: max(packet.data.count, 1)
        )
        compressed.packetCount = 1
        compressed.byteLength = UInt32(packet.data.count)
        packet.data.copyBytes(
            to: compressed.data.bindMemory(to: UInt8.self, capacity: packet.data.count),
            count: packet.data.count
        )

        // Max Opus frame: 120 ms @ 48 kHz = 5760 samples
        guard let pcmBuf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 5760) else {
            return nil
        }

        var convError: NSError?
        let status = converter.convert(to: pcmBuf, error: &convError) { _, outStatus in
            outStatus.pointee = .haveData
            return compressed
        }

        if status == .error {
            log("decode error: \(convError?.localizedDescription ?? "unknown")")
            return nil
        }

        // Apply pre-skip: discard the first `preSkip` samples
        if preSkipRemaining > 0 && pcmBuf.frameLength > 0 {
            let skip = min(preSkipRemaining, Int(pcmBuf.frameLength))
            preSkipRemaining -= skip
            if skip == Int(pcmBuf.frameLength) { return nil }  // entirely pre-skip

            let remaining = Int(pcmBuf.frameLength) - skip
            guard let trimmed = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(remaining)) else {
                return nil
            }
            trimmed.frameLength = AVAudioFrameCount(remaining)
            let channelCount = Int(pcmFormat.channelCount)
            for ch in 0..<channelCount {
                guard let src = pcmBuf.floatChannelData?[ch],
                      let dst = trimmed.floatChannelData?[ch] else { continue }
                dst.update(from: src.advanced(by: skip), count: remaining)
            }
            return trimmed
        }

        return pcmBuf
    }
}
