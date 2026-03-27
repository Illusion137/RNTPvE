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
public class QueuedAudioPlayer: AudioPlayer, QueueManagerDelegate {
    let queue: QueueManager = QueueManager<AudioItem>()
    fileprivate var lastIndex: Int = -1
    fileprivate var lastItem: AudioItem? = nil
    private var secondaryWrapper: AVPlayerWrapper? = nil
    private var crossfadeTimer: DispatchSourceTimer? = nil
    private var isCrossfading: Bool = false
    private var suppressPrimaryEndEvent: Bool = false
    private var crossfadeBaseVolume: Float? = nil
    private var secondaryIndex: Int? = nil
    private var isPromotingSecondaryWrapper: Bool = false
    private var promotedWrapper: AVPlayerWrapper? = nil

    public override init(nowPlayingInfoController: NowPlayingInfoControllerProtocol = NowPlayingInfoController(), remoteCommandController: RemoteCommandController = RemoteCommandController()) {
        super.init(nowPlayingInfoController: nowPlayingInfoController, remoteCommandController: remoteCommandController)
        queue.delegate = self
    }

    /// The repeat mode for the queue player.
    public var repeatMode: RepeatMode = .off

    /// Duration in seconds to crossfade between tracks. Currently stored but not applied natively.
    public var crossfadeDuration: Double = 0

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
        cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
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
        cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
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
        cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
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
        cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
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
        cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
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
        cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
        seek(to: 0);
        play()
    }

    override public func stop() {
        cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
        super.stop()
    }

    override public func seek(to seconds: TimeInterval) {
        cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
        super.seek(to: seconds)
    }

    override public func seek(by offset: TimeInterval) {
        cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
        super.seek(by: offset)
    }

    override public func setEqualizerBands(_ bands: [Float]) {
        super.setEqualizerBands(bands)
        secondaryWrapper?.setEqualizerBands(eqBandsSnapshot)
    }

    override public func removeEqualizer() {
        super.removeEqualizer()
        secondaryWrapper?.resetEqualizer()
    }

    override public func setEqualizerEnabled(_ enabled: Bool) {
        super.setEqualizerEnabled(enabled)
        secondaryWrapper?.setEqualizerEnabled(enabled)
    }

    private func nextIndexForTransition() -> Int? {
        guard currentIndex >= 0 && !items.isEmpty else { return nil }
        switch repeatMode {
        case .track:
            return nil
        case .off:
            let candidate = currentIndex + 1
            return candidate < items.count ? candidate : nil
        case .queue:
            guard items.count > 1 else { return nil }
            let candidate = currentIndex + 1
            return candidate < items.count ? candidate : 0
        }
    }

    private func configureWrapperForSecondaryUse(_ target: AVPlayerWrapper) {
        target.rate = wrapper.rate
        target.bufferDuration = wrapper.bufferDuration
        target.automaticallyWaitsToMinimizeStalling = wrapper.automaticallyWaitsToMinimizeStalling
        target.timeEventFrequency = wrapper.timeEventFrequency
        target.volume = wrapper.volume
        target.crossfadeVolume = 1.0
        target.isMuted = wrapper.isMuted
        applyEqualizerSnapshot(to: target)
    }

    private func prepareSecondaryWrapperIfNeeded(for index: Int) {
        guard index >= 0 && index < items.count else { return }
        if secondaryIndex == index, secondaryWrapper != nil { return }

        secondaryWrapper?.stop()
        secondaryWrapper = nil
        secondaryIndex = nil

        let item = items[index]
        let secondary = AVPlayerWrapper()
        configureWrapperForSecondaryUse(secondary)
        load(item: item, into: secondary, updateContext: false, playWhenReady: false)

        secondaryWrapper = secondary
        secondaryIndex = index
    }

    private func maybePrepareOrStartCrossfade(currentTime: TimeInterval) {
        guard playWhenReady else { return }
        guard let nextIndex = nextIndexForTransition() else {
            // Required behavior: no secondary track means no fade, even with crossfade enabled.
            cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
            return
        }

        let total = duration
        guard total > 0, currentTime >= 0 else { return }
        let remaining = total - currentTime
        guard remaining >= 0 else { return }

        let preloadLeadTime = max(crossfadeDuration, 3)
        if remaining <= preloadLeadTime {
            prepareSecondaryWrapperIfNeeded(for: nextIndex)
        }

        guard crossfadeDuration > 0 else { return }
        guard !isCrossfading, remaining <= crossfadeDuration else { return }
        beginCrossfade(targetIndex: nextIndex)
    }

    private func beginCrossfade(targetIndex: Int) {
        prepareSecondaryWrapperIfNeeded(for: targetIndex)
        guard let secondary = secondaryWrapper, secondaryIndex == targetIndex else { return }
        guard !isCrossfading else { return }

        isCrossfading = true
        suppressPrimaryEndEvent = true
        let baseVolume = wrapper.volume
        crossfadeBaseVolume = baseVolume
        wrapper.crossfadeVolume = 1.0
        secondary.crossfadeVolume = 0
        secondary.play()

        let duration = max(0.01, crossfadeDuration)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let primary = wrapper

        crossfadeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        crossfadeTimer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            let progress = max(0, min(1, elapsed / duration))
            let p = Float(progress)
            primary.crossfadeVolume = 1 - p
            secondary.crossfadeVolume = p
            if progress >= 1 {
                self.completeCrossfade(targetIndex: targetIndex, baseVolume: baseVolume)
            }
        }
        timer.resume()
    }

    private func completeCrossfade(targetIndex: Int, baseVolume: Float) {
        crossfadeTimer?.cancel()
        crossfadeTimer = nil
        isCrossfading = false
        crossfadeBaseVolume = baseVolume
        event.playbackEnd.emit(data: .playedUntilEnd)
        promotePreparedSecondary(to: targetIndex)
    }

    private func promotePreparedSecondary(to index: Int) {
        guard let promoted = secondaryWrapper, secondaryIndex == index else { return }

        promoted.crossfadeVolume = 1.0
        promoted.volume = crossfadeBaseVolume ?? wrapper.volume
        promoted.playWhenReady = playWhenReady

        isPromotingSecondaryWrapper = true
        promotedWrapper = promoted
        secondaryWrapper = nil
        secondaryIndex = nil

        let oldIndex = currentIndex
        _ = queue.next(wrap: repeatMode == .queue)
        if isPromotingSecondaryWrapper && currentIndex == oldIndex {
            isPromotingSecondaryWrapper = false
            promotedWrapper = nil
            promoted.stop()
            suppressPrimaryEndEvent = false
        }
    }

    private func cancelCrossfadeAndSecondary(resetPrimaryVolume: Bool) {
        crossfadeTimer?.cancel()
        crossfadeTimer = nil
        isCrossfading = false
        suppressPrimaryEndEvent = false

        if resetPrimaryVolume, let base = crossfadeBaseVolume {
            wrapper.volume = base
        }
        wrapper.crossfadeVolume = 1.0
        crossfadeBaseVolume = nil

        secondaryWrapper?.stop()
        secondaryWrapper = nil
        secondaryIndex = nil

        promotedWrapper = nil
        isPromotingSecondaryWrapper = false
    }

    // MARK: - AVPlayerWrapperDelegate

    override func AVWrapper(secondsElapsed seconds: Double) {
        super.AVWrapper(secondsElapsed: seconds)
        maybePrepareOrStartCrossfade(currentTime: seconds)
    }

    override func AVWrapperItemDidPlayToEndTime() {
        if suppressPrimaryEndEvent {
            suppressPrimaryEndEvent = false
            return
        }

        event.playbackEnd.emit(data: .playedUntilEnd)

        if crossfadeDuration <= 0,
           let nextIndex = nextIndexForTransition(),
           secondaryWrapper != nil,
           secondaryIndex == nextIndex {
            promotePreparedSecondary(to: nextIndex)
            return
        }

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
        let lastPosition = currentTime

        if isPromotingSecondaryWrapper, let promoted = promotedWrapper, let currentItem = currentItem {
            isPromotingSecondaryWrapper = false
            promotedWrapper = nil
            crossfadeTimer?.cancel()
            crossfadeTimer = nil
            isCrossfading = false
            suppressPrimaryEndEvent = false

            let base = crossfadeBaseVolume ?? wrapper.volume
            swapPrimaryWrapper(with: promoted)
            applyEqualizerSnapshot(to: promoted)
            promoted.volume = base
            promoted.crossfadeVolume = 1.0
            promoted.playWhenReady = playWhenReady
            updateCurrentItemContext(currentItem)
        } else if let currentItem = currentItem {
            cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
            super.load(item: currentItem)
        } else {
            cancelCrossfadeAndSecondary(resetPrimaryVolume: true)
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

}
