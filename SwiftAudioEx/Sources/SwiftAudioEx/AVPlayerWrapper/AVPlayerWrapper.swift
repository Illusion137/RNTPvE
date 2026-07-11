//
//  AVPlayerWrapper.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 06/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import Foundation
import AVFoundation
import MediaPlayer

public enum PlaybackEndedReason: String {
    case playedUntilEnd
    case playerStopped
    case skippedToNext
    case skippedToPrevious
    case jumpedToIndex
    case cleared
    case failed
}

class AVPlayerWrapper: AVPlayerWrapperProtocol {
    // MARK: - Properties

    enum PlaybackBackend: Equatable {
        case sabrStream
        case localOpusFile
        case defaultAVPlayer
    }

    fileprivate var avPlayer = AVPlayer()
    private let playerObserver = AVPlayerObserver()
    internal let playerTimeObserver: AVPlayerTimeObserver
    private let playerItemNotificationObserver = AVPlayerItemNotificationObserver()
    private let playerItemObserver = AVPlayerItemObserver()
    fileprivate var timeToSeekToAfterLoading: TimeInterval?
    fileprivate var asset: AVAsset? = nil
    fileprivate var item: AVPlayerItem? = nil
    fileprivate var url: URL? = nil
    fileprivate var urlOptions: [String: Any]? = nil
    private var sabrOpusPlayer: SabrOpusPlayer? = nil
    private var _lastExplicitVolume: Float = 1.0
    private var _crossfadeVolume: Float = 1.0
    private var _isMuted: Bool = false
    var onSabrRefreshPoToken: ((String) -> Void)? = nil
    var onSabrReloadPlayerResponse: ((String?) -> Void)? = nil
    /// Wall-clock time when the opus player started playing (adjusted for pauses).
    private var opusPlayStartDate: Date? = nil
    /// Wall-clock time when opus was paused (nil when not paused).
    private var opusPausedAt: Date? = nil
    /// Periodic timer that drives secondsElapsed callbacks for the Opus path.
    private var opusTimer: Timer? = nil
    fileprivate var passedDuration: TimeInterval?
    fileprivate var sourceType: SourceType?

    fileprivate let stateQueue = DispatchQueue(
        label: "AVPlayerWrapper.stateQueue",
        attributes: .concurrent
    )

    // MARK: - Audio Processing (Equalizer)

    /// Audio tap processor for real-time EQ on streaming content
    private let audioTapProcessor = AudioTapProcessor()

    /// Whether to apply audio processing tap
    var audioProcessingEnabled: Bool = true

    public init() {
        playerTimeObserver = AVPlayerTimeObserver(periodicObserverTimeInterval: timeEventFrequency.getTime())

        playerObserver.delegate = self
        playerTimeObserver.delegate = self
        playerItemNotificationObserver.delegate = self
        playerItemObserver.delegate = self

        setupAVPlayer();
    }

    // MARK: - AVPlayerWrapperProtocol

    fileprivate(set) var playbackError: AudioPlayerError.PlaybackError? = nil

    var _state: AVPlayerWrapperState = AVPlayerWrapperState.idle
    var state: AVPlayerWrapperState {
        get {
            var state: AVPlayerWrapperState!
            stateQueue.sync {
                state = _state
            }

            return state
        }
        set {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                let currentState = self._state
                if (currentState != newValue) {
                    self._state = newValue
                    self.delegate?.AVWrapper(didChangeState: newValue)
                }
            }
        }
    }

    fileprivate(set) var lastPlayerTimeControlStatus: AVPlayer.TimeControlStatus = AVPlayer.TimeControlStatus.paused

    /**
     Whether AVPlayer should start playing automatically when the item is ready.
     */
    public var playWhenReady: Bool = false {
        didSet {
            if (playWhenReady == true && (state == .failed || state == .stopped)) {
                reload(startFromCurrentTime: state == .failed)
            }

            applyAVPlayerRate()

            // Sync state for Opus path (avPlayer status changes are ignored for this path).
            // timeToSeekToAfterLoading != nil means a seek reload is in flight — stay in
            // .loading; onDidStartPlaying will set the correct state and timer.
            if sabrOpusPlayer != nil, opusPlayStartDate != nil, timeToSeekToAfterLoading == nil, oldValue != playWhenReady {
                state = playWhenReady ? .playing : .paused
                if playWhenReady { startOpusTimer() } else { stopOpusTimer() }
            }

            if oldValue != playWhenReady {
                delegate?.AVWrapper(didChangePlayWhenReady: playWhenReady)
            }
        }
    }

    var currentItem: AVPlayerItem? {
        avPlayer.currentItem
    }

    var playbackActive: Bool {
        switch state {
        case .idle, .stopped, .ended, .failed:
            return false
        default: return true
        }
    }

    var currentTime: TimeInterval {
        // Opus path: AVPlayer has no item, so track elapsed wall-clock time instead.
        if sabrOpusPlayer != nil {
            guard let start = opusPlayStartDate else { return 0 }
            if let pausedAt = opusPausedAt {
                return pausedAt.timeIntervalSince(start)
            }
            return Date().timeIntervalSince(start)
        }
        let seconds = avPlayer.currentTime().seconds
        return seconds.isNaN ? 0 : seconds
    }

    var duration: TimeInterval {
        // Opus path: passedDuration is always authoritative (no AVPlayerItem)
        if sabrOpusPlayer != nil, let d = passedDuration, !d.isNaN {
            return d
        }
        if sourceType == .stream, let duration = passedDuration, !duration.isNaN {
            return duration
        }
        if let seconds = currentItem?.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.asset.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.seekableTimeRanges.last?.timeRangeValue.duration.seconds,
                !seconds.isNaN {
            return seconds
        }
        return 0.0
    }

    var bufferedPosition: TimeInterval {
        if sabrOpusPlayer != nil { return duration }
        return currentItem?.loadedTimeRanges.last?.timeRangeValue.end.seconds ?? 0
    }

    var reasonForWaitingToPlay: AVPlayer.WaitingReason? {
        avPlayer.reasonForWaitingToPlay
    }

    private var _rate: Float = 1.0;
    var rate: Float {
        get { _rate }
        set {
            _rate = newValue
            applyAVPlayerRate()
        }
    }

    weak var delegate: AVPlayerWrapperDelegate? = nil

    var bufferDuration: TimeInterval = 0

    var timeEventFrequency: TimeEventFrequency = .everySecond {
        didSet {
            playerTimeObserver.periodicObserverTimeInterval = timeEventFrequency.getTime()
            if opusTimer != nil { startOpusTimer() }  // restart with new interval
        }
    }

    var volume: Float {
        get { _lastExplicitVolume }
        set {
            _lastExplicitVolume = newValue
            applyOutputLevels()
        }
    }

    var isMuted: Bool {
        get { _isMuted }
        set {
            _isMuted = newValue
            applyOutputLevels()
        }
    }

    var crossfadeVolume: Float {
        get { _crossfadeVolume }
        set {
            _crossfadeVolume = max(0, min(1, newValue))
            applyOutputLevels()
        }
    }

    var automaticallyWaitsToMinimizeStalling: Bool {
        get { avPlayer.automaticallyWaitsToMinimizeStalling }
        set { avPlayer.automaticallyWaitsToMinimizeStalling = newValue }
    }

    func play() {
        playWhenReady = true
    }

    func pause() {
        playWhenReady = false
    }

    func togglePlaying() {
        if sabrOpusPlayer != nil {
            playWhenReady ? pause() : play()
            return
        }
        switch avPlayer.timeControlStatus {
        case .playing, .waitingToPlayAtSpecifiedRate:
            pause()
        case .paused:
            play()
        @unknown default:
            fatalError("Unknown AVPlayer.timeControlStatus")
        }
    }

    func stop() {
        state = .stopped
        clearCurrentItem()
        self.sourceType = nil
        self.passedDuration = nil
        playWhenReady = false
    }

    func seek(to seconds: TimeInterval) {
        if let opus = sabrOpusPlayer {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in self?.seek(to: seconds) }
                return
            }
            let effectiveDuration = duration > 0 ? duration : Double.infinity
            let clamped = max(0, min(seconds, effectiveDuration))
            if opus.sabrStream == nil {
                // File mode: restart pipeline from seek target
                timeToSeekToAfterLoading = clamped
                // Freeze the reported position at the seek target while the pipeline
                // reloads — otherwise currentTime briefly reads 0 (scrubber snaps back,
                // and a concurrent seek(by:) would compound off the wrong position).
                opusPlayStartDate = Date().addingTimeInterval(-clamped)
                opusPausedAt = Date()
                stopOpusTimer()
                state = .loading
                opus.seek(to: clamped * 1000)
                delegate?.AVWrapper(seekTo: Double(clamped), didFinish: true)
            } else {
                // SABR stream mode: restart the stream from seek position.
                // Wall-clock adjustment alone only changes displayed position — the server
                // continues sending from where it left off. Restarting loadSABR() with
                // startTimeMs tells the server to begin at the seek target via player_time_ms.
                timeToSeekToAfterLoading = clamped
                // Same freeze-at-target as file mode (see above).
                opusPlayStartDate = Date().addingTimeInterval(-clamped)
                opusPausedAt = Date()
                stopOpusTimer()
                sabrOpusPlayer?.cancel()
                sabrOpusPlayer = nil
                state = .loading
                let targetMs = clamped * 1000
                let maxDurationMs: Double
                if let passedDuration {
                    maxDurationMs = max(0, passedDuration * 1000)
                } else if duration > 0 {
                    maxDurationMs = max(0, duration * 1000)
                } else {
                    maxDurationMs = targetMs
                }
                loadSABR(startTimeMs: max(0, min(targetMs, maxDurationMs)))
                delegate?.AVWrapper(seekTo: Double(clamped), didFinish: true)
            }
            return
        }
        // if the player is loading then we need to defer seeking until it's ready.
        if (avPlayer.currentItem == nil) {
            timeToSeekToAfterLoading = seconds
        } else {
            let time = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1000)
            avPlayer.seek(to: time, toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero) { (finished) in
                self.delegate?.AVWrapper(seekTo: Double(seconds), didFinish: finished)
            }
        }
    }

    func seek(by seconds: TimeInterval) {
        if sabrOpusPlayer != nil {
            seek(to: currentTime + seconds)
            return
        }
        if let currentItem = avPlayer.currentItem {
            let time = currentItem.currentTime().seconds + seconds
            avPlayer.seek(
                to: CMTimeMakeWithSeconds(time, preferredTimescale: 1000)
            ) { (finished) in
                  self.delegate?.AVWrapper(seekTo: Double(time), didFinish: finished)
            }
        } else {
            if let timeToSeekToAfterLoading = timeToSeekToAfterLoading {
                self.timeToSeekToAfterLoading = timeToSeekToAfterLoading + seconds
            } else {
                timeToSeekToAfterLoading = seconds
            }
        }
    }

    private func playbackFailed(error: AudioPlayerError.PlaybackError) {
        state = .failed
        self.playbackError = error
        self.delegate?.AVWrapper(failedWithError: error)
    }

    private func effectiveOutputVolume() -> Float {
        if _isMuted { return 0 }
        return _lastExplicitVolume * _crossfadeVolume
    }

    private func applyOutputLevels() {
        let output = effectiveOutputVolume()
        if let opus = sabrOpusPlayer {
            DispatchQueue.main.async {
                opus.engine.mainMixerNode.outputVolume = output
            }
        } else {
            avPlayer.volume = output
            avPlayer.isMuted = _isMuted
        }
    }

    func load() {
        if (state == .failed) {
            recreateAVPlayer()
        } else {
            clearCurrentItem()
        }
        if let url = url {
            switch AVPlayerWrapper.resolvePlaybackBackend(url: url, options: urlOptions) {
            case .sabrStream:
                loadSABR()
                return
            case .localOpusFile:
                loadOpusFile(url: url)
                return
            case .defaultAVPlayer:
                break
            }

            // AVPlayer default path (normal URLs, HLS, and supported local files).
            let pendingAsset = AVURLAsset(url: url, options: urlOptions)
            asset = pendingAsset
            state = .loading

            // Load metadata keys asynchronously and separate from playable, to allow that to execute as quickly as it can
            let metdataKeys = ["commonMetadata", "availableChapterLocales", "availableMetadataFormats"]
            pendingAsset.loadValuesAsynchronously(forKeys: metdataKeys, completionHandler: { [weak self] in
                guard let self = self else { return }
                if (pendingAsset != self.asset) { return; }

                let commonData = pendingAsset.commonMetadata
                if (!commonData.isEmpty) {
                    self.delegate?.AVWrapper(didReceiveCommonMetadata: commonData)
                }

                if pendingAsset.availableChapterLocales.count > 0 {
                    for locale in pendingAsset.availableChapterLocales {
                        let chapters = pendingAsset.chapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: nil)
                        self.delegate?.AVWrapper(didReceiveChapterMetadata: chapters)
                    }
                } else {
                    for format in pendingAsset.availableMetadataFormats {
                        let timeRange = CMTimeRange(start: CMTime(seconds: 0, preferredTimescale: 1000), end: pendingAsset.duration)
                        let group = AVTimedMetadataGroup(items: pendingAsset.metadata(forFormat: format), timeRange: timeRange)
                        self.delegate?.AVWrapper(didReceiveTimedMetadata: [group])
                    }
                }
            })

            // Load playable portion of the track and commence when ready
            let playableKeys = ["playable"]
            pendingAsset.loadValuesAsynchronously(forKeys: playableKeys, completionHandler: { [weak self] in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    if (pendingAsset != self.asset) { return; }

                    for key in playableKeys {
                        var error: NSError?
                        let keyStatus = pendingAsset.statusOfValue(forKey: key, error: &error)
                        switch keyStatus {
                        case .failed:
                            self.playbackFailed(error: AudioPlayerError.PlaybackError.failedToLoadKeyValue)
                            return
                        case .cancelled, .loading, .unknown:
                            return
                        case .loaded:
                            break
                        default: break
                        }
                    }

                    if (!pendingAsset.isPlayable) {
                        self.playbackFailed(error: AudioPlayerError.PlaybackError.itemWasUnplayable)
                        return;
                    }

                    let item = AVPlayerItem(
                        asset: pendingAsset,
                        automaticallyLoadedAssetKeys: playableKeys
                    )
                    self.item = item;
                    item.preferredForwardBufferDuration = self.bufferDuration

                    // Apply audio processing tap for equalizer (on main thread to avoid race conditions)
                    if self.audioProcessingEnabled {
                        self.applyAudioTap(to: item, asset: pendingAsset)
                    }

                    self.avPlayer.replaceCurrentItem(with: item)
                    self.startObservingAVPlayer(item: item)
                    self.applyAVPlayerRate()

                    if let initialTime = self.timeToSeekToAfterLoading {
                        self.timeToSeekToAfterLoading = nil
                        self.seek(to: initialTime)
                    }
                }
            })
        }
    }

    func load(from url: URL, playWhenReady: Bool, options: [String: Any]? = nil) {
        self.playWhenReady = playWhenReady
        self.url = url
        self.urlOptions = options
        self.load()
    }

    func load(
        from url: URL,
        playWhenReady: Bool,
        initialTime: TimeInterval? = nil,
        options: [String : Any]? = nil
    ) {
        self.load(from: url, playWhenReady: playWhenReady, options: options)
        if let initialTime = initialTime {
            self.seek(to: initialTime)
        }
    }

    func load(
        from url: String,
        type: SourceType = .stream,
        playWhenReady: Bool = false,
        initialTime: TimeInterval? = nil,
        options: [String : Any]? = nil,
        duration: Double? = nil
    ) {
        self.sourceType = type
        self.passedDuration = duration

        let itemUrl: URL?
        if type == .file {
            // Accept both absolute paths ("/var/...") and file URLs ("file:///var/...")
            if let parsed = URL(string: url), parsed.isFileURL {
                itemUrl = parsed
            } else {
                itemUrl = URL(fileURLWithPath: url)
            }
        } else {
            itemUrl = URL(string: url)
        }

        if let itemUrl {
            self.load(from: itemUrl, playWhenReady: playWhenReady, options: options)
            if let initialTime = initialTime {
                self.seek(to: initialTime)
            }
        } else {
            clearCurrentItem()
            playbackFailed(error: AudioPlayerError.PlaybackError.invalidSourceUrl(url))
        }
    }

    /// Puts the wrapper into a "waiting for source" state for an item whose URL is not known yet.
    /// The wrapper reports `.loading` (so UIs show a spinner and the queue treats playback as
    /// active) until a real source arrives via a subsequent `load(...)` call.
    func prepareForPendingSource(playWhenReady: Bool, duration: Double? = nil) {
        if (state == .failed) {
            recreateAVPlayer()
        } else {
            clearCurrentItem()
        }
        playbackError = nil
        url = nil
        urlOptions = nil
        asset = nil
        item = nil
        timeToSeekToAfterLoading = nil
        // Report the expected duration while there is no AVPlayerItem to derive it from.
        sourceType = .stream
        passedDuration = duration
        state = .loading
        self.playWhenReady = playWhenReady
    }

    func unload() {
        clearCurrentItem()
        self.sourceType = nil
        self.passedDuration = nil
        state = .idle
    }

    func reload(startFromCurrentTime: Bool) {
        var time : Double? = nil
        if (startFromCurrentTime) {
            if let currentItem = currentItem {
                if (!currentItem.duration.isIndefinite) {
                    time = currentItem.currentTime().seconds
                }
            }
        }
        load()
        if let time = time {
            seek(to: time)
        }
    }

    // MARK: - SABR

    private func loadSABR(startTimeMs: Double = 0) {
        guard let options = urlOptions,
              let serverUrl = options["sabrServerUrl"] as? String,
              let ustreamerConfig = options["sabrUstreamerConfig"] as? String else {
            playbackFailed(error: AudioPlayerError.PlaybackError.failedToLoadKeyValue)
            return
        }

        let formatsData = options["sabrFormats"] as? [[String: Any]] ?? []
        let formats = formatsData.compactMap { SabrFormat(dictionary: $0) }
        let poToken = options["poToken"] as? String

        let config = SabrStreamConfig(
            server_abr_streaming_url: serverUrl,
            video_playback_ustreamer_config: ustreamerConfig,
            po_token: poToken,
            duration_ms: passedDuration.map { $0 * 1000 },
            formats: formats
        )

        let stream = SabrStream(config: config)

        let player = SabrOpusPlayer(stream: stream)
        sabrOpusPlayer = player
        applyOutputLevels()

        player.onRefreshPoToken = { [weak self] reason in
            guard let self, self.sabrOpusPlayer === player else { return }
            self.onSabrRefreshPoToken?(reason)
        }
        player.onReloadPlayerResponse = { [weak self] token in
            guard let self, self.sabrOpusPlayer === player else { return }
            self.onSabrReloadPlayerResponse?(token)
        }
        player.onDurationUpdated = { [weak self] durationMs in
            guard let self, self.sabrOpusPlayer === player else { return }
            let durationSec = durationMs / 1000.0
            self.passedDuration = durationSec
            DispatchQueue.main.async {
                guard self.sabrOpusPlayer === player else { return }
                self.delegate?.AVWrapper(didUpdateDuration: durationSec)
            }
        }

        let currentBands = audioTapProcessor.getEQBands()
        if currentBands.contains(where: { $0 != 0 }) { player.setEQBands(currentBands) }
        player.setEQEnabled(audioTapProcessor.isEnabled)

        player.onDidStartPlaying = { [weak self] in
            guard let self, self.sabrOpusPlayer === player else { return }
            NSLog("[SabrOpusPlayer] T+\(player.elapsedMs())ms: onDidStartPlaying fired")
            // Set state immediately — the state setter is thread-safe (barrier dispatch).
            self.state = self.playWhenReady ? .playing : .paused
            DispatchQueue.main.async {
                guard self.sabrOpusPlayer === player else { return }
                self.anchorOpusClock()
            }
        }

        player.onDidFinishPlaying = { [weak self] in
            guard let self, self.sabrOpusPlayer === player else { return }
            self.state = .ended
            DispatchQueue.main.async {
                self.stopOpusTimer()
                self.delegate?.AVWrapperItemDidPlayToEndTime()
            }
        }

        player.onDidFailPlaying = { [weak self] in
            guard let self, self.sabrOpusPlayer === player else { return }
            DispatchQueue.main.async {
                self.stopOpusTimer()
                self.playbackFailed(error: AudioPlayerError.PlaybackError.playbackFailed)
            }
        }

        player.onEngineStarted = { [weak self] in
            guard let self, self.sabrOpusPlayer === player else { return }
            NSLog("[SabrOpusPlayer] T+\(player.elapsedMs())ms: onEngineStarted fired")
            DispatchQueue.main.async { self.applyAVPlayerRate() }
        }

        state = .loading
        if let d = passedDuration, d > 0 {
            delegate?.AVWrapper(didUpdateDuration: d)
        }

        let durationMs = (passedDuration ?? 0) * 1000
        let playbackOptions = SabrPlaybackOptions(enabled_track_types: EnabledTrackTypes.audio_only)
        player.prepareAudioSession()
        player.start(options: playbackOptions, durationMs: durationMs, startTimeMs: startTimeMs)
    }

    private func loadOpusFile(url: URL) {
        let player = SabrOpusPlayer()
        sabrOpusPlayer = player
        applyOutputLevels()

        let currentBands = audioTapProcessor.getEQBands()
        if currentBands.contains(where: { $0 != 0 }) { player.setEQBands(currentBands) }
        player.setEQEnabled(audioTapProcessor.isEnabled)

        player.onDidStartPlaying = { [weak self] in
            guard let self, self.sabrOpusPlayer === player else { return }
            NSLog("[SabrOpusPlayer] T+\(player.elapsedMs())ms: onDidStartPlaying fired")
            // Set state immediately — the state setter is thread-safe (barrier dispatch).
            // This avoids the DispatchQueue.main.async delay that stalls in RN apps.
            self.state = self.playWhenReady ? .playing : .paused
            // Timer and date tracking must be on main thread.
            DispatchQueue.main.async {
                guard self.sabrOpusPlayer === player else { return }
                self.anchorOpusClock()
            }
        }
        player.onDidFinishPlaying = { [weak self] in
            guard let self, self.sabrOpusPlayer === player else { return }
            self.state = .ended
            DispatchQueue.main.async {
                self.stopOpusTimer()
                self.delegate?.AVWrapperItemDidPlayToEndTime()
            }
        }
        player.onDidFailPlaying = { [weak self] in
            guard let self, self.sabrOpusPlayer === player else { return }
            DispatchQueue.main.async {
                self.stopOpusTimer()
                self.playbackFailed(error: AudioPlayerError.PlaybackError.playbackFailed)
            }
        }
        player.onEngineStarted = { [weak self] in
            guard let self, self.sabrOpusPlayer === player else { return }
            NSLog("[SabrOpusPlayer] T+\(player.elapsedMs())ms: onEngineStarted fired")
            DispatchQueue.main.async { self.applyAVPlayerRate() }
        }

        state = .loading
        if let d = passedDuration, d > 0 {
            delegate?.AVWrapper(didUpdateDuration: d)
        }
        let durationMs = (passedDuration ?? 0) * 1000
        player.prepareAudioSession()
        player.startFile(url: url, durationMs: durationMs)
    }

    // MARK: - Util

    /// Returns true if the file at `url` starts with the EBML magic bytes (1A 45 DF A3),
    /// identifying it as a WebM/MKV container regardless of file extension.
    private static func isWebMFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 4)
        return header.count == 4 &&
               header[0] == 0x1A && header[1] == 0x45 &&
               header[2] == 0xDF && header[3] == 0xA3
    }

    static func resolvePlaybackBackend(url: URL, options: [String: Any]?) -> PlaybackBackend {
        if options?["isSabr"] as? Bool == true {
            return .sabrStream
        }

        if url.isFileURL {
            let isExplicit = options?["isOpus"] as? Bool == true
            let ext = url.pathExtension.lowercased()
            let knownExt = ["webm", "opus"].contains(ext)
            if isExplicit || knownExt || isWebMFile(url) {
                return .localOpusFile
            }
        }

        // Default AVPlayer path covers normal/progressive URLs, local AVFoundation
        // file URLs (non-Opus/WebM), and HLS streams (including .m3u8 manifests).
        return .defaultAVPlayer
    }

    /// (Re)anchors wall-clock position tracking once the opus pipeline reports audio flowing.
    /// Handles loads that finish while paused (position stays frozen until resume) and
    /// pending seeks. Must run on the main thread.
    private func anchorOpusClock() {
        let now = Date()
        if let initialTime = timeToSeekToAfterLoading {
            timeToSeekToAfterLoading = nil
            opusPlayStartDate = now.addingTimeInterval(-initialTime)
        } else if let pausedAt = opusPausedAt, let previousStart = opusPlayStartDate {
            // Was frozen mid-track (paused before or during the load): keep the frozen
            // position, re-anchored to now.
            opusPlayStartDate = now.addingTimeInterval(-pausedAt.timeIntervalSince(previousStart))
        } else {
            opusPlayStartDate = now
        }
        if playWhenReady {
            opusPausedAt = nil
            startOpusTimer()
        } else {
            // Loaded while paused: freeze at the current position until resume.
            opusPausedAt = now
        }
    }

    private func startOpusTimer() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startOpusTimer() }
            return
        }
        opusTimer?.invalidate()
        let interval = timeEventFrequency.getTime().seconds
        opusTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.delegate?.AVWrapper(secondsElapsed: self.currentTime)
        }
    }

    private func stopOpusTimer() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stopOpusTimer() }
            return
        }
        opusTimer?.invalidate()
        opusTimer = nil
    }

    private func clearCurrentItem() {
        stopOpusTimer()
        sabrOpusPlayer?.cancel()
        sabrOpusPlayer = nil
        opusPlayStartDate = nil
        opusPausedAt = nil

        guard let asset = asset else { return }
        stopObservingAVPlayerItem()

        asset.cancelLoading()
        self.asset = nil

        avPlayer.replaceCurrentItem(with: nil)
    }

    private func startObservingAVPlayer(item: AVPlayerItem) {
        playerItemObserver.startObserving(item: item)
        playerItemNotificationObserver.startObserving(item: item)
    }

    private func stopObservingAVPlayerItem() {
        playerItemObserver.stopObservingCurrentItem()
        playerItemNotificationObserver.stopObservingCurrentItem()
    }

    private func recreateAVPlayer() {
        playbackError = nil
        playerTimeObserver.unregisterForBoundaryTimeEvents()
        playerTimeObserver.unregisterForPeriodicEvents()
        playerObserver.stopObserving()
        stopObservingAVPlayerItem()
        clearCurrentItem()
        self.sourceType = nil
        self.passedDuration = nil

        avPlayer = AVPlayer();
        setupAVPlayer()
        applyOutputLevels()

        delegate?.AVWrapperDidRecreateAVPlayer()
    }

    private func setupAVPlayer() {
        // disabled since we're not making use of video playback
        avPlayer.allowsExternalPlayback = false;

        playerObserver.player = avPlayer
        playerObserver.startObserving()

        playerTimeObserver.player = avPlayer
        playerTimeObserver.registerForBoundaryTimeEvents()
        playerTimeObserver.registerForPeriodicTimeEvents()

        applyAVPlayerRate()
    }

    private func applyAVPlayerRate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.applyAVPlayerRate() }
            return
        }
        if let opusPlayer = sabrOpusPlayer {
            if playWhenReady {
                if !opusPlayer.playerNode.isPlaying && opusPlayer.engine.isRunning {
                    opusPlayer.playerNode.play()
                }
                if let pausedAt = opusPausedAt {
                    // Shift startDate forward by however long we were paused
                    opusPlayStartDate = opusPlayStartDate.map { $0.addingTimeInterval(Date().timeIntervalSince(pausedAt)) }
                    opusPausedAt = nil
                }
            } else {
                if opusPlayer.playerNode.isPlaying {
                    opusPlayer.playerNode.pause()
                }
                // Freeze the wall-clock position even when the node isn't technically
                // playing (still loading, engine stopped, underrun) — otherwise
                // currentTime keeps advancing while the UI shows paused.
                if opusPausedAt == nil {
                    opusPausedAt = Date()
                }
            }
        } else {
            avPlayer.rate = playWhenReady ? _rate : 0
        }
        applyOutputLevels()
    }
}

extension AVPlayerWrapper: AVPlayerObserverDelegate {

    // MARK: - AVPlayerObserverDelegate

    func player(didChangeTimeControlStatus status: AVPlayer.TimeControlStatus) {
        // Opus path uses SabrOpusPlayer — avPlayer has no item, so its status changes are irrelevant.
        guard sabrOpusPlayer == nil else { return }
        switch status {
        case .paused:
            let state = self.state
            if self.asset == nil && state != .stopped {
                self.state = .idle
            } else if (state != .failed && state != .stopped) {
                // Playback may have become paused externally for example due to a bluetooth device disconnecting:
                if (self.playWhenReady) {
                    if (self.currentTime > 0 && self.currentTime < self.duration) {
                        self.playWhenReady = false;
                    }
                } else {
                    // Only if we are not on the boundaries of the track, otherwise itemDidPlayToEndTime will handle it instead.
                    self.state = .paused
                }
            }
        case .waitingToPlayAtSpecifiedRate:
            if self.asset != nil {
                self.state = .buffering
            }
        case .playing:
            self.state = .playing
        @unknown default:
            break
        }
    }

    func player(statusDidChange status: AVPlayer.Status) {
        if (status == .failed) {
            let error = item!.error as NSError?
            playbackFailed(error: error?.code == URLError.notConnectedToInternet.rawValue
                 ? AudioPlayerError.PlaybackError.notConnectedToInternet
                 : AudioPlayerError.PlaybackError.playbackFailed
            )
        }
    }
}

extension AVPlayerWrapper: AVPlayerTimeObserverDelegate {

    // MARK: - AVPlayerTimeObserverDelegate

    func audioDidStart() {
        state = .playing
    }

    func timeEvent(time: CMTime) {
        delegate?.AVWrapper(secondsElapsed: time.seconds)
    }

}

extension AVPlayerWrapper: AVPlayerItemNotificationObserverDelegate {
    // MARK: - AVPlayerItemNotificationObserverDelegate

    func itemFailedToPlayToEndTime() {
        playbackFailed(error: AudioPlayerError.PlaybackError.playbackFailed)
        delegate?.AVWrapperItemFailedToPlayToEndTime()
    }

    func itemPlaybackStalled() {
        delegate?.AVWrapperItemPlaybackStalled()
    }

    func itemDidPlayToEndTime() {
        delegate?.AVWrapperItemDidPlayToEndTime()
    }

}

// MARK: - Equalizer

extension AVPlayerWrapper {

    /// Apply audio tap to player item (with safe track loading)
    func applyAudioTap(to item: AVPlayerItem, asset: AVAsset) {
        // Check if tracks are available
        let tracks = asset.tracks(withMediaType: .audio)
        if !tracks.isEmpty {
            // Tracks available, apply tap now
            if let audioMix = audioTapProcessor.createAudioMix(for: item) {
                item.audioMix = audioMix
            }
        } else {
            // For streaming content, tracks might load later
            // Load tracks asynchronously
            if #available(iOS 15.0, macOS 12.0, *) {
                Task {
                    do {
                        let loadedTracks = try await asset.loadTracks(withMediaType: .audio)
                        if !loadedTracks.isEmpty {
                            await MainActor.run {
                                if let audioMix = self.audioTapProcessor.createAudioMix(for: item) {
                                    item.audioMix = audioMix
                                }
                            }
                        }
                    } catch {
                        // Audio tap not available for this content - not critical
                        print("AVPlayerWrapper: Could not load audio tracks for EQ: \(error)")
                    }
                }
            }
        }
    }

    func updateSabrStreamPoToken(_ poToken: String) {
        sabrOpusPlayer?.updatePoToken(poToken)
    }

    /// Set equalizer bands (gain in dB, -24 to +24)
    func setEqualizerBands(_ bands: [Float]) {
        audioTapProcessor.setEQBands(bands)
        sabrOpusPlayer?.setEQBands(bands)
        if bands.contains(where: { $0 != 0 }) {
            sabrOpusPlayer?.setEQEnabled(true)
        }
    }

    /// Get current equalizer bands
    func getEqualizerBands() -> [Float] {
        if let opus = sabrOpusPlayer { return opus.getEQBands() }
        return audioTapProcessor.getEQBands()
    }

    /// Reset equalizer to flat
    func resetEqualizer() {
        audioTapProcessor.resetEQ()
        sabrOpusPlayer?.resetEQ()
    }

    /// Enable/disable equalizer processing
    func setEqualizerEnabled(_ enabled: Bool) {
        audioTapProcessor.isEnabled = enabled
        sabrOpusPlayer?.setEQEnabled(enabled)
    }

    /// Check if equalizer is enabled
    func isEqualizerEnabled() -> Bool {
        return audioTapProcessor.isEnabled
    }
}

extension AVPlayerWrapper: AVPlayerItemObserverDelegate {
    // MARK: - AVPlayerItemObserverDelegate

    func item(didUpdatePlaybackLikelyToKeepUp playbackLikelyToKeepUp: Bool) {
        if (playbackLikelyToKeepUp && state != .playing) {
            state = .ready
        }
    }

    func item(didUpdateDuration duration: Double) {
        delegate?.AVWrapper(didUpdateDuration: duration)
    }

    func item(didReceiveTimedMetadata metadata: [AVTimedMetadataGroup]) {
        delegate?.AVWrapper(didReceiveTimedMetadata: metadata)
    }
}
