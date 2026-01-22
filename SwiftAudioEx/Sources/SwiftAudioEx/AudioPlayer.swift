//
//  AudioPlayer.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 15/03/2018.
//

import Foundation
import MediaPlayer

public typealias AudioPlayerState = AVPlayerWrapperState

public class AudioPlayer: AVPlayerWrapperDelegate {
    
    // MARK: - Properties
    
    /// The wrapper around AVPlayer with integrated equalizer support via MTAudioProcessingTap
    private let avPlayerWrapper: AVPlayerWrapper
    
    /// Convenient access to the wrapper
    var wrapper: AVPlayerWrapperProtocol {
        return avPlayerWrapper
    }

    public let nowPlayingInfoController: NowPlayingInfoControllerProtocol
    public let remoteCommandController: RemoteCommandController
    public let event = EventHolder()

    private(set) var currentItem: AudioItem?

    /**
     Set this to false to disable automatic updating of now playing info for control center and lock screen.
     */
    public var automaticallyUpdateNowPlayingInfo: Bool = true

    /**
     Controls the time pitch algorithm applied to each item loaded into the player.
     If the loaded `AudioItem` conforms to `TimePitcher`-protocol this will be overriden.
     */
    public var audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm = AVAudioTimePitchAlgorithm.timeDomain

    /**
     Default remote commands to use for each playing item
     */
    public var remoteCommands: [RemoteCommand] = [] {
        didSet {
            if let item = currentItem {
                self.enableRemoteCommands(forItem: item)
            }
        }
    }

    internal func handlePlayWhenReady(_ playWhenReady: Bool?, action: () throws -> Void) rethrows {
        if playWhenReady == false {
            self.playWhenReady = false
        }
        
        try action()
        
        if playWhenReady == true, playbackError == nil {
            self.playWhenReady = true
        }
    }

    // MARK: - Getters from Wrapper

    public var playbackError: AudioPlayerError.PlaybackError? {
        wrapper.playbackError
    }
    
    public var currentTime: Double {
        wrapper.currentTime
    }

    public var duration: Double {
        wrapper.duration
    }

    public var bufferedPosition: Double {
        wrapper.bufferedPosition
    }

    public var playerState: AudioPlayerState {
        wrapper.state
    }

    // MARK: - Setters for Wrapper

    public var playWhenReady: Bool {
        get { wrapper.playWhenReady }
        set { wrapper.playWhenReady = newValue }
    }
    
    public var bufferDuration: TimeInterval {
        get { wrapper.bufferDuration }
        set {
            wrapper.bufferDuration = newValue
            wrapper.automaticallyWaitsToMinimizeStalling = newValue == 0
        }
    }

    public var automaticallyWaitsToMinimizeStalling: Bool {
        get { wrapper.automaticallyWaitsToMinimizeStalling }
        set {
            if newValue {
                wrapper.bufferDuration = 0
            }
            wrapper.automaticallyWaitsToMinimizeStalling = newValue
        }
    }
    
    public var timeEventFrequency: TimeEventFrequency {
        get { wrapper.timeEventFrequency }
        set { wrapper.timeEventFrequency = newValue }
    }

    public var volume: Float {
        get { wrapper.volume }
        set { wrapper.volume = newValue }
    }

    public var isMuted: Bool {
        get { wrapper.isMuted }
        set { wrapper.isMuted = newValue }
    }

    public var rate: Float {
        get { wrapper.rate }
        set {
            wrapper.rate = newValue
            if automaticallyUpdateNowPlayingInfo {
                updateNowPlayingPlaybackValues()
            }
        }
    }

    // MARK: - Init

    public init(nowPlayingInfoController: NowPlayingInfoControllerProtocol = NowPlayingInfoController(),
                remoteCommandController: RemoteCommandController = RemoteCommandController()) {
        self.nowPlayingInfoController = nowPlayingInfoController
        self.remoteCommandController = remoteCommandController

        // Initialize AVPlayerWrapper with integrated equalizer support
        avPlayerWrapper = AVPlayerWrapper()
        avPlayerWrapper.delegate = self
        
        self.remoteCommandController.audioPlayer = self
    }

    // MARK: - Player Actions

    public func load(item: AudioItem, playWhenReady: Bool? = nil) {
        handlePlayWhenReady(playWhenReady) {
            currentItem = item

            if automaticallyUpdateNowPlayingInfo {
                nowPlayingInfoController.setWithoutUpdate(keyValues: [
                    MediaItemProperty.duration(nil),
                    NowPlayingInfoProperty.playbackRate(nil),
                    NowPlayingInfoProperty.elapsedPlaybackTime(nil)
                ])
                loadNowPlayingMetaValues()
            }
            
            enableRemoteCommands(forItem: item)
            
            wrapper.load(
                from: item.getSourceUrl(),
                type: item.getSourceType(),
                playWhenReady: self.playWhenReady,
                initialTime: (item as? InitialTiming)?.getInitialTime(),
                options: (item as? AssetOptionsProviding)?.getAssetOptions()
            )
        }
    }

    public func togglePlaying() {
        wrapper.togglePlaying()
    }

    public func play() {
        wrapper.play()
    }

    public func pause() {
        wrapper.pause()
    }

    public func stop() {
        let wasActive = wrapper.playbackActive
        wrapper.stop()
        if wasActive {
            event.playbackEnd.emit(data: .playerStopped)
        }
    }

    public func reload(startFromCurrentTime: Bool) {
        wrapper.reload(startFromCurrentTime: startFromCurrentTime)
    }
    
    public func seek(to seconds: TimeInterval) {
        wrapper.seek(to: seconds)
    }

    public func seek(by offset: TimeInterval) {
        wrapper.seek(by: offset)
    }
    
    // MARK: - Remote Command Center

    func enableRemoteCommands(_ commands: [RemoteCommand]) {
        remoteCommandController.enable(commands: commands)
    }

    func enableRemoteCommands(forItem item: AudioItem) {
        if let item = item as? RemoteCommandable {
            self.enableRemoteCommands(item.getCommands())
        } else {
            self.enableRemoteCommands(remoteCommands)
        }
    }

    @available(*, deprecated, message: "Directly set .remoteCommands instead")
    public func syncRemoteCommandsWithCommandCenter() {
        self.enableRemoteCommands(remoteCommands)
    }

    // MARK: - NowPlayingInfo

    public func loadNowPlayingMetaValues() {
        guard let item = currentItem else { return }

        nowPlayingInfoController.set(keyValues: [
            MediaItemProperty.artist(item.getArtist()),
            MediaItemProperty.title(item.getTitle()),
            MediaItemProperty.albumTitle(item.getAlbumTitle()),
        ])
        loadArtwork(forItem: item)
    }

    func updateNowPlayingPlaybackValues() {
        nowPlayingInfoController.set(keyValues: [
            MediaItemProperty.duration(wrapper.duration),
            NowPlayingInfoProperty.playbackRate(wrapper.playWhenReady ? Double(wrapper.rate) : 0),
            NowPlayingInfoProperty.elapsedPlaybackTime(wrapper.currentTime)
        ])
    }

    public func clear() {
        let playbackWasActive = wrapper.playbackActive
        currentItem = nil
        wrapper.unload()
        nowPlayingInfoController.clear()
        if playbackWasActive {
            event.playbackEnd.emit(data: .cleared)
        }
    }

    // MARK: - Private

    private func setNowPlayingCurrentTime(seconds: Double) {
        nowPlayingInfoController.set(
            keyValue: NowPlayingInfoProperty.elapsedPlaybackTime(seconds)
        )
    }

    private func loadArtwork(forItem item: AudioItem) {
        item.getArtwork { (image) in
            if let image = image {
                let artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: { _ in image })
                self.nowPlayingInfoController.set(keyValue: MediaItemProperty.artwork(artwork))
            } else {
                self.nowPlayingInfoController.set(keyValue: MediaItemProperty.artwork(nil))
            }
        }
    }

    private func setTimePitchingAlgorithmForCurrentItem() {
        if let item = currentItem as? TimePitching {
            wrapper.currentItem?.audioTimePitchAlgorithm = item.getPitchAlgorithmType()
        } else {
            wrapper.currentItem?.audioTimePitchAlgorithm = audioTimePitchAlgorithm
        }
    }

    // MARK: - AVPlayerWrapperDelegate

    func AVWrapper(didChangeState state: AVPlayerWrapperState) {
        switch state {
        case .ready, .loading:
            setTimePitchingAlgorithmForCurrentItem()
        default: break
        }

        switch state {
        case .ready, .loading, .playing, .paused:
            if automaticallyUpdateNowPlayingInfo {
                updateNowPlayingPlaybackValues()
            }
        default: break
        }
        event.stateChange.emit(data: state)
    }

    func AVWrapper(secondsElapsed seconds: Double) {
        event.secondElapse.emit(data: seconds)
    }

    func AVWrapper(failedWithError error: Error?) {
        event.fail.emit(data: error)
        event.playbackEnd.emit(data: .failed)
    }

    func AVWrapper(seekTo seconds: Double, didFinish: Bool) {
        if automaticallyUpdateNowPlayingInfo {
            setNowPlayingCurrentTime(seconds: Double(seconds))
        }
        event.seek.emit(data: (seconds, didFinish))
    }

    func AVWrapper(didUpdateDuration duration: Double) {
        event.updateDuration.emit(data: duration)
    }
    
    func AVWrapper(didReceiveCommonMetadata metadata: [AVMetadataItem]) {
        event.receiveCommonMetadata.emit(data: metadata)
    }
    
    func AVWrapper(didReceiveChapterMetadata metadata: [AVTimedMetadataGroup]) {
        event.receiveChapterMetadata.emit(data: metadata)
    }
    
    func AVWrapper(didReceiveTimedMetadata metadata: [AVTimedMetadataGroup]) {
        event.receiveTimedMetadata.emit(data: metadata)
    }

    func AVWrapper(didChangePlayWhenReady playWhenReady: Bool) {
        event.playWhenReadyChange.emit(data: playWhenReady)
    }
    
    func AVWrapperItemDidPlayToEndTime() {
        event.playbackEnd.emit(data: .playedUntilEnd)
        wrapper.state = .ended
    }

    func AVWrapperItemFailedToPlayToEndTime() {
        AVWrapper(failedWithError: AudioPlayerError.PlaybackError.playbackFailed)
    }

    func AVWrapperItemPlaybackStalled() {
    }
    
    func AVWrapperDidRecreateAVPlayer() {
        event.didRecreateAVPlayer.emit(data: ())
    }
    
    // MARK: - Equalizer
    
    /**
     Set equalizer bands. Each value represents gain in decibels.
     - parameter bands: Array of gain values for each frequency band (10 bands)
     - Note: Gain values are in decibels (dB). Range is -24 to +24 dB.
     - Note: Frequencies: 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz
     - Note: Equalizer works with BOTH local files AND streaming URLs via MTAudioProcessingTap
     */
    public func setEqualizerBands(_ bands: [Float]) {
        avPlayerWrapper.setEqualizerBands(bands)
    }
    
    /**
     Get the current equalizer bands.
     - returns: Array of gain values for each frequency band
     */
    public func getEqualizerBands() -> [Float] {
        return avPlayerWrapper.getEqualizerBands()
    }
    
    /**
     Reset the equalizer to flat (all bands at 0 dB).
     */
    public func removeEqualizer() {
        avPlayerWrapper.resetEqualizer()
    }
    
    /**
     Enable or disable equalizer processing.
     - parameter enabled: Whether to enable EQ processing
     */
    public func setEqualizerEnabled(_ enabled: Bool) {
        avPlayerWrapper.setEqualizerEnabled(enabled)
    }
    
    /**
     Check if equalizer is currently enabled.
     - returns: True if EQ is enabled
     */
    public func isEqualizerActive() -> Bool {
        return avPlayerWrapper.isEqualizerEnabled()
    }
}
