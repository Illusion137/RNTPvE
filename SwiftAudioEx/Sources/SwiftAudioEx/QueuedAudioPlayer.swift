//
//  QueuedAudioPlayer.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 24/03/2018.
//

import Foundation
import MediaPlayer

/**
 An audio player that can keep track of a queue of AudioItems.
 */
public class QueuedAudioPlayer: AudioPlayer, QueueManagerDelegate, CrossfadeManagerDelegate {
    let queue: QueueManager = QueueManager<AudioItem>()
    fileprivate var lastIndex: Int = -1
    fileprivate var lastItem: AudioItem? = nil
    private let crossfadeManager = CrossfadeManager()
    private var isCrossfading: Bool = false
    private var crossfadeTimer: Timer? = nil
    private var nextPlayerWrapper: AVPlayerWrapper? = nil
    private var crossfadeStartTime: TimeInterval = 0
    private var crossfadeNextPlayerTime: TimeInterval = 0
    private var crossfadeNextPlayerWasPlaying: Bool = false
    private var isFinishingCrossfade: Bool = false

    public override init(nowPlayingInfoController: NowPlayingInfoControllerProtocol = NowPlayingInfoController(), remoteCommandController: RemoteCommandController = RemoteCommandController()) {
        super.init(nowPlayingInfoController: nowPlayingInfoController, remoteCommandController: remoteCommandController)
        queue.delegate = self
        crossfadeManager.delegate = self
    }

    /// The repeat mode for the queue player.
    public var repeatMode: RepeatMode = .off
    
    /**
     Set the crossfade duration in seconds. When a track is within this duration from the end,
     the next track will start playing and crossfade with the current track.
     Set to 0 to disable crossfade.
     */
    public var crossfadeDuration: TimeInterval {
        get {
            return crossfadeManager.getCrossfadeDuration()
        }
        set {
            crossfadeManager.setCrossfadeDuration(newValue)
        }
    }

    public override var currentItem: AudioItem? {
        queue.current
    }

    /**
     The index of the current item.
     */
    public var currentIndex: Int {
        queue.currentIndex
    }

    override public func clear() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        nextPlayerWrapper?.stop()
        nextPlayerWrapper = nil
        crossfadeManager.reset()
        isCrossfading = false
        queue.clearQueue()
        super.clear()
    }

    /**
     All items currently in the queue.
     */
    public var items: [AudioItem] {
        queue.items
    }

    /**
     The previous items held by the queue.
     */
    public var previousItems: [AudioItem] {
        queue.previousItems
    }

    /**
     The upcoming items in the queue.
     */
    public var nextItems: [AudioItem] {
        queue.nextItems
    }

    /**
     Will replace the current item with a new one and load it into the player.

     - parameter item: The AudioItem to replace the current item.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public override func load(item: AudioItem, playWhenReady: Bool? = nil) {
        handlePlayWhenReady(playWhenReady) {
            queue.replaceCurrentItem(with: item)
        }
    }

    /**
     Add a single item to the queue.

     - parameter item: The item to add.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public func add(item: AudioItem, playWhenReady: Bool? = nil) {
        handlePlayWhenReady(playWhenReady) {
            queue.add(item)
        }
    }

    /**
     Add items to the queue.

     - parameter items: The items to add to the queue.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public func add(items: [AudioItem], playWhenReady: Bool? = nil) {
        handlePlayWhenReady(playWhenReady) {
            queue.add(items)
        }
    }

    public func add(items: [AudioItem], at index: Int) throws {
        try queue.add(items, at: index)
    }

    /**
     Step to the next item in the queue.
     */
    public func next() {
        let lastIndex = currentIndex
        let playbackWasActive = wrapper.playbackActive;
        _ = queue.next(wrap: repeatMode == .queue)
        if (playbackWasActive && lastIndex != currentIndex || repeatMode == .queue) {
            event.playbackEnd.emit(data: .skippedToNext)
        }
    }

    /**
     Step to the previous item in the queue.
     */
    public func previous() {
        let lastIndex = currentIndex
        let playbackWasActive = wrapper.playbackActive;
        _ = queue.previous(wrap: repeatMode == .queue)
        if (playbackWasActive && lastIndex != currentIndex || repeatMode == .queue) {
            event.playbackEnd.emit(data: .skippedToPrevious)
        }
    }

    /**
     Remove an item from the queue.

     - parameter index: The index of the item to remove.
     - throws: `AudioPlayerError.QueueError`
     */
    public func removeItem(at index: Int) throws {
        try queue.removeItem(at: index)
    }


    /**
     Jump to a certain item in the queue.

     - parameter index: The index of the item to jump to.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     - throws: `AudioPlayerError`
     */
    public func jumpToItem(atIndex index: Int, playWhenReady: Bool? = nil) throws {
        try handlePlayWhenReady(playWhenReady) {
            if (index == currentIndex) {
                seek(to: 0)
            } else {
                _ = try queue.jump(to: index)
            }
            event.playbackEnd.emit(data: .jumpedToIndex)
        }
    }

    /**
     Move an item in the queue from one position to another.

     - parameter fromIndex: The index of the item to move.
     - parameter toIndex: The index to move the item to.
     - throws: `AudioPlayerError.QueueError`
     */
    public func moveItem(fromIndex: Int, toIndex: Int) throws {
        try queue.moveItem(fromIndex: fromIndex, toIndex: toIndex)
    }

    /**
     Remove all upcoming items, those returned by `next()`
     */
    public func removeUpcomingItems() {
        queue.removeUpcomingItems()
    }

    /**
     Remove all previous items, those returned by `previous()`
     */
    public func removePreviousItems() {
        queue.removePreviousItems()
    }

    func replay() {
        seek(to: 0);
        play()
    }

    // MARK: - AVPlayerWrapperDelegate
    
    override func AVWrapper(secondsElapsed seconds: Double) {
        super.AVWrapper(secondsElapsed: seconds)
        // Update crossfade manager with current track info
        crossfadeManager.updateTrackInfo(duration: wrapper.duration, position: wrapper.currentTime)
    }

    override func AVWrapperItemDidPlayToEndTime() {
        event.playbackEnd.emit(data: .playedUntilEnd)
        if (repeatMode == .track) {
            self.pause()

            // quick workaround for race condition - schedule a call after 2 frames
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016 * 2) { [weak self] in self?.replay() }
        } else if (repeatMode == .queue) {
            _ = queue.next(wrap: true)
        } else if (currentIndex != items.count - 1) {
            _ = queue.next(wrap: false)
        } else {
            wrapper.state = .ended
        }
    }

    // MARK: - QueueManagerDelegate

    func onCurrentItemChanged() {
        let lastPosition = currentTime;
        
        // Stop any crossfade next player if still active (unless we're finishing crossfade)
        if let nextPlayer = nextPlayerWrapper, !isFinishingCrossfade {
            nextPlayer.stop()
            nextPlayerWrapper = nil
        }
        
        // Always reset crossfade manager for new track (enables repeated crossfades)
        // Only skip during active crossfade animation
        if !isCrossfading {
            crossfadeManager.reset()
            wrapper.volume = 1.0
        }
        
        // Always load the current item - this ensures the main wrapper has the correct track
        // For crossfade: we need to load the new track so EQ is applied via audio tap
        if let currentItem = currentItem {
            // When finishing crossfade, don't auto-play - we'll handle that manually
            if isFinishingCrossfade {
                super.load(item: currentItem, playWhenReady: false)
            } else {
                super.load(item: currentItem)
            }
        } else {
            super.clear()
        }
        
        event.currentItem.emit(
            data: (
                item: currentItem,
                index: currentIndex == -1 ? nil : currentIndex,
                lastItem: lastItem,
                lastIndex: lastIndex == -1 ? nil : lastIndex,
                lastPosition: lastPosition
            )
        )
        lastItem = currentItem
        lastIndex = currentIndex
    }

    func onSkippedToSameCurrentItem() {
        if (wrapper.playbackActive) {
            replay()
        }
    }

    func onReceivedFirstItem() {
        try! queue.jump(to: 0)
    }
    
    // MARK: - CrossfadeManagerDelegate
    
    func crossfadeShouldStartNextTrack() {
        // Check if there's a next track
        guard nextItems.count > 0 || (repeatMode == .queue && items.count > 0) else {
            return
        }
        
        guard !isCrossfading else { return }
        guard crossfadeDuration > 0 else { return }
        
        // Determine next track index
        let nextIndex: Int
        if currentIndex < items.count - 1 {
            nextIndex = currentIndex + 1
        } else if repeatMode == .queue && items.count > 0 {
            nextIndex = 0
        } else {
            return // No next track
        }
        
        guard nextIndex < items.count else { return }
        let nextItem = items[nextIndex]
        let wasPlaying = wrapper.playbackActive
        
        guard wasPlaying else { return }
        
        // Create and preload next player
        nextPlayerWrapper = AVPlayerWrapper()
        guard let nextPlayer = nextPlayerWrapper else { return }
        
        // Load next track into the second player
        let urlString = nextItem.getSourceUrl()
        nextPlayer.load(from: urlString, type: nextItem.getSourceType(), playWhenReady: false, initialTime: nil, options: (nextItem as? AssetOptionsProviding)?.getAssetOptions())
        
        // Set up a delegate to monitor when next player is ready
        let crossfadeDelegate = CrossfadePlayerDelegate { [weak self] in
            self?.startCrossfadeAnimation()
        }
        nextPlayer.delegate = crossfadeDelegate
        
        // Also try to start after a short delay as fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if !self.isCrossfading, let nextPlayer = self.nextPlayerWrapper {
                // Check if player is ready
                if nextPlayer.state == .ready || nextPlayer.state == .playing || nextPlayer.state == .loading {
                    self.startCrossfadeAnimation()
                }
            }
        }
    }
    
    private func startCrossfadeAnimation() {
        guard let nextPlayer = nextPlayerWrapper else { return }
        guard !isCrossfading else { return }
        
        isCrossfading = true
        crossfadeStartTime = Date().timeIntervalSince1970
        
        // Start next player at volume 0
        nextPlayer.volume = 0.0
        nextPlayer.play()
        
        // Fade out current, fade in next
        let steps = 30
        let stepDuration = crossfadeDuration / Double(steps)
        var step = 0
        
        crossfadeTimer?.invalidate()
        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
            guard let self = self, let nextPlayer = self.nextPlayerWrapper else {
                timer.invalidate()
                return
            }
            
            step += 1
            let progress = min(1.0, Double(step) / Double(steps))
            
            // Fade out current track
            self.wrapper.volume = Float(1.0 - progress)
            
            // Fade in next track
            nextPlayer.volume = Float(progress)
            
            if step >= steps || progress >= 1.0 {
                timer.invalidate()
                self.finishCrossfade()
            }
        }
        
        if let timer = crossfadeTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func finishCrossfade() {
        guard let nextPlayer = nextPlayerWrapper else {
            isCrossfading = false
            isFinishingCrossfade = false
            crossfadeManager.resetPreloadFlag()
            return
        }
        
        // Save the next player's state BEFORE stopping it
        crossfadeNextPlayerTime = nextPlayer.currentTime
        crossfadeNextPlayerWasPlaying = nextPlayer.playbackActive
        
        // Stop current wrapper and ensure volume is restored
        wrapper.pause()
        wrapper.volume = 1.0
        
        // Mark that we're finishing crossfade
        isCrossfading = false
        isFinishingCrossfade = true
        
        // Stop next player - we're done with it
        nextPlayer.pause()
        nextPlayer.stop()
        nextPlayerWrapper = nil
        
        // Move to next track in queue - this triggers onCurrentItemChanged
        // which will reset the crossfade manager and load the new track
        _ = queue.next(wrap: repeatMode == .queue)
        
        // The load happens in onCurrentItemChanged. After it completes, seek to the right position.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            
            // Ensure volume is at full
            self.wrapper.volume = 1.0
            
            // Seek to where the crossfaded track was playing (skip if near start)
            if self.crossfadeNextPlayerTime > 0.5 {
                self.seek(to: self.crossfadeNextPlayerTime)
            }
            
            // Resume playback if it was playing
            if self.crossfadeNextPlayerWasPlaying {
                self.play()
            }
            
            // Reset crossfade state
            self.crossfadeNextPlayerTime = 0
            self.crossfadeNextPlayerWasPlaying = false
            self.isFinishingCrossfade = false
        }
    }
    
}

// Helper delegate for crossfade next player
private class CrossfadePlayerDelegate: AVPlayerWrapperDelegate {
    let onReady: () -> Void
    
    init(onReady: @escaping () -> Void) {
        self.onReady = onReady
    }
    
    func AVWrapper(didChangeState state: AVPlayerWrapperState) {
        if state == .ready || state == .playing {
            onReady()
        }
    }
    
    func AVWrapper(secondsElapsed seconds: Double) {}
    func AVWrapper(failedWithError error: Error?) {}
    func AVWrapper(seekTo seconds: Double, didFinish: Bool) {}
    func AVWrapper(didUpdateDuration duration: Double) {}
    func AVWrapper(didReceiveCommonMetadata metadata: [AVMetadataItem]) {}
    func AVWrapper(didReceiveChapterMetadata metadata: [AVTimedMetadataGroup]) {}
    func AVWrapper(didReceiveTimedMetadata metadata: [AVTimedMetadataGroup]) {}
    func AVWrapper(didChangePlayWhenReady playWhenReady: Bool) {}
    func AVWrapperItemDidPlayToEndTime() {}
    func AVWrapperItemFailedToPlayToEndTime() {}
    func AVWrapperItemPlaybackStalled() {}
    func AVWrapperDidRecreateAVPlayer() {}
}
