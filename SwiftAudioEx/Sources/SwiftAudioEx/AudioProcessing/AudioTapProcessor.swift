//
//  AudioTapProcessor.swift
//  SwiftAudioEx
//
//  Implements MTAudioProcessingTap for real-time audio processing with AVPlayer
//  This allows equalizer to work with streaming URLs, not just local files
//

import Foundation
import AVFoundation

/// Context for each audio tap - stores per-tap state
private class AudioTapContext {
    weak var processor: AudioTapProcessor?
    var filterStates: [[[Double]]] = [] // [channel][band][state]
    var channelCount: Int = 2
    var sampleRate: Double = 44100
    
    init(processor: AudioTapProcessor) {
        self.processor = processor
    }
}

/// Processes audio through MTAudioProcessingTap with EQ support
public class AudioTapProcessor {
    
    // MARK: - Properties
    
    /// Equalizer bands (gain in dB, -24 to +24)
    private var eqBands: [Float] = Array(repeating: 0, count: 10)
    
    /// Standard frequencies for 10-band EQ
    private let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    
    /// Biquad filter coefficients for each band
    private var filterCoefficients: [[Double]] = []
    
    /// Lock for thread-safe coefficient updates
    private let lock = NSLock()
    
    /// Whether EQ is enabled
    public var isEnabled: Bool = true
    
    // MARK: - Initialization
    
    public init() {
        initializeDefaultCoefficients(sampleRate: 44100)
    }
    
    private func initializeDefaultCoefficients(sampleRate: Double) {
        filterCoefficients = []
        for _ in frequencies {
            // Identity filter (passthrough): b0=1, b1=0, b2=0, a1=0, a2=0
            filterCoefficients.append([1.0, 0.0, 0.0, 0.0, 0.0])
        }
    }
    
    // MARK: - Public API
    
    /// Set equalizer bands
    public func setEQBands(_ bands: [Float]) {
        var newBands = bands.map { max(-24, min(24, $0)) }
        while newBands.count < 10 {
            newBands.append(0)
        }
        
        lock.lock()
        eqBands = newBands
        recalculateCoefficients()
        lock.unlock()
    }
    
    /// Get current EQ bands
    public func getEQBands() -> [Float] {
        lock.lock()
        let bands = eqBands
        lock.unlock()
        return bands
    }
    
    /// Reset EQ to flat
    public func resetEQ() {
        setEQBands(Array(repeating: 0, count: 10))
    }
    
    /// Get thread-safe copy of current coefficients
    func getCoefficients() -> [[Double]] {
        lock.lock()
        let coeffs = filterCoefficients
        lock.unlock()
        return coeffs
    }
    
    /// Create an audio mix with processing tap for the given player item
    public func createAudioMix(for playerItem: AVPlayerItem) -> AVMutableAudioMix? {
        let asset = playerItem.asset
        
        // Try to get audio track
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            return nil
        }
        
        // Create the audio mix
        let audioMix = AVMutableAudioMix()
        
        // Create input parameters for the audio track
        let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        
        // Create context for this tap
        let context = AudioTapContext(processor: self)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        
        // Create the processing tap
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(contextPtr),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        )
        
        guard status == noErr, let audioTap = tap else {
            // Release context if tap creation failed
            Unmanaged<AudioTapContext>.fromOpaque(contextPtr).release()
            return nil
        }
        
        inputParams.audioTapProcessor = audioTap.takeRetainedValue()
        audioMix.inputParameters = [inputParams]
        
        return audioMix
    }
    
    // MARK: - Filter Coefficient Calculation
    
    private func recalculateCoefficients() {
        filterCoefficients = []
        for (index, frequency) in frequencies.enumerated() {
            let gain = index < eqBands.count ? eqBands[index] : 0
            let coeffs = calculatePeakingEQCoefficients(
                frequency: Double(frequency),
                gain: Double(gain),
                Q: 1.41,
                sampleRate: 44100 // Will be recalculated per-tap in prepare
            )
            filterCoefficients.append(coeffs)
        }
    }
    
    func calculateCoefficients(sampleRate: Double) -> [[Double]] {
        lock.lock()
        let bands = eqBands
        lock.unlock()
        
        var coeffs: [[Double]] = []
        for (index, frequency) in frequencies.enumerated() {
            let gain = index < bands.count ? bands[index] : 0
            let c = calculatePeakingEQCoefficients(
                frequency: Double(frequency),
                gain: Double(gain),
                Q: 1.41,
                sampleRate: sampleRate
            )
            coeffs.append(c)
        }
        return coeffs
    }
    
    private func calculatePeakingEQCoefficients(frequency: Double, gain: Double, Q: Double, sampleRate: Double) -> [Double] {
        // If gain is essentially 0, return identity filter
        if abs(gain) < 0.01 {
            return [1.0, 0.0, 0.0, 0.0, 0.0]
        }
        
        let A = pow(10, gain / 40.0)
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * Q)
        
        let b0 = 1.0 + alpha * A
        let b1 = -2.0 * cosOmega
        let b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha / A
        
        // Normalize coefficients
        return [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
    }
}

// MARK: - MTAudioProcessingTap Callbacks

private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    // Release the context
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioTapContext>.fromOpaque(storage).release()
}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
    
    let format = processingFormat.pointee
    context.sampleRate = format.mSampleRate
    context.channelCount = max(1, Int(format.mChannelsPerFrame))
    
    // Initialize filter states for this tap
    context.filterStates = []
    for _ in 0..<context.channelCount {
        var channelStates: [[Double]] = []
        for _ in 0..<10 { // 10 bands
            channelStates.append([0, 0, 0, 0]) // x[n-1], x[n-2], y[n-1], y[n-2]
        }
        context.filterStates.append(channelStates)
    }
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    // Clear filter states
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
    context.filterStates = []
}

private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    // Get the source audio
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        flagsOut,
        nil,
        numberFramesOut
    )
    
    guard status == noErr, numberFramesOut.pointee > 0 else { return }
    
    // Get context
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
    
    guard let processor = context.processor, processor.isEnabled else { return }
    guard !context.filterStates.isEmpty else { return }
    
    // Get current coefficients (thread-safe read)
    let coeffs = processor.calculateCoefficients(sampleRate: context.sampleRate)
    guard coeffs.count == 10 else { return }
    
    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    let frameCount = Int(numberFramesOut.pointee)
    
    for bufferIndex in 0..<bufferList.count {
        guard let data = bufferList[bufferIndex].mData else { continue }
        
        let floatData = data.assumingMemoryBound(to: Float.self)
        let channelIndex = bufferIndex % context.channelCount
        
        guard channelIndex < context.filterStates.count else { continue }
        
        // Process each sample through all EQ bands
        for frameIndex in 0..<frameCount {
            var sample = Double(floatData[frameIndex])
            
            // Apply each band's filter
            for bandIndex in 0..<coeffs.count {
                guard bandIndex < context.filterStates[channelIndex].count else { continue }
                
                let c = coeffs[bandIndex]
                guard c.count >= 5 else { continue }
                
                let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
                
                // Skip identity filters
                if b0 == 1.0 && b1 == 0.0 && b2 == 0.0 && a1 == 0.0 && a2 == 0.0 {
                    continue
                }
                
                let x0 = sample
                let x1 = context.filterStates[channelIndex][bandIndex][0]
                let x2 = context.filterStates[channelIndex][bandIndex][1]
                let y1 = context.filterStates[channelIndex][bandIndex][2]
                let y2 = context.filterStates[channelIndex][bandIndex][3]
                
                // Biquad filter
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                
                // Update state
                context.filterStates[channelIndex][bandIndex][0] = x0
                context.filterStates[channelIndex][bandIndex][1] = x1
                context.filterStates[channelIndex][bandIndex][2] = y0
                context.filterStates[channelIndex][bandIndex][3] = y1
                
                sample = y0
            }
            
            // Clamp to prevent clipping
            floatData[frameIndex] = Float(max(-1.0, min(1.0, sample)))
        }
    }
}
