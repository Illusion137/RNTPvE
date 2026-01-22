//
//  CrossfadeManager.swift
//  SwiftAudioEx
//
//  Created for crossfade functionality
//

import Foundation
import AVFoundation

protocol CrossfadeManagerDelegate: AnyObject {
    func crossfadeShouldStartNextTrack()
}

class CrossfadeManager {
    weak var delegate: CrossfadeManagerDelegate?
    
    private var crossfadeDuration: TimeInterval = 0
    private var isCrossfadeEnabled: Bool {
        return crossfadeDuration > 0
    }
    
    private var currentTrackDuration: TimeInterval = 0
    private var currentTrackPosition: TimeInterval = 0
    private var nextTrackPreloaded: Bool = false
    
    func setCrossfadeDuration(_ duration: TimeInterval) {
        crossfadeDuration = max(0, duration)
    }
    
    func getCrossfadeDuration() -> TimeInterval {
        return crossfadeDuration
    }
    
    func updateTrackInfo(duration: TimeInterval, position: TimeInterval) {
        currentTrackDuration = duration
        currentTrackPosition = position
        
        checkCrossfadeThreshold()
    }
    
    func reset() {
        // Full reset - always reset everything for a new track
        nextTrackPreloaded = false
        currentTrackDuration = 0
        currentTrackPosition = 0
    }
    
    func resetPreloadFlag() {
        nextTrackPreloaded = false
    }
    
    private func checkCrossfadeThreshold() {
        guard isCrossfadeEnabled else { return }
        guard currentTrackDuration > 0 else { return }
        
        let timeRemaining = currentTrackDuration - currentTrackPosition
        let threshold = crossfadeDuration
        
        if timeRemaining <= threshold && !nextTrackPreloaded {
            nextTrackPreloaded = true
            delegate?.crossfadeShouldStartNextTrack()
        }
    }
}

