import Foundation
import SwiftProtobuf

// MARK: - TimeRange wrapper

/// Wrapper around VideoStreaming_TimeRange with optional snake_case properties.
struct TimeRange {
    var timescale: Int?
    var duration_ticks: String?
    var start_ticks: String?

    init() {}
    init(timescale: Int? = nil, duration_ticks: String? = nil, start_ticks: String? = nil) {
        self.timescale = timescale
        self.duration_ticks = duration_ticks
        self.start_ticks = start_ticks
    }

    init(proto: VideoStreaming_TimeRange) {
        self.timescale = proto.hasTimescale ? Int(proto.timescale) : nil
        self.duration_ticks = proto.hasDurationTicks ? String(proto.durationTicks) : nil
        self.start_ticks = proto.hasStartTicks ? String(proto.startTicks) : nil
    }

    var proto: VideoStreaming_TimeRange {
        var t = VideoStreaming_TimeRange()
        if let ts = timescale { t.timescale = Int32(ts) }
        if let dt = duration_ticks.flatMap({ Int64($0) }) { t.durationTicks = dt }
        if let st = start_ticks.flatMap({ Int64($0) }) { t.startTicks = st }
        return t
    }
}

// MARK: - MediaHeader wrapper

/// Wrapper around VideoStreaming_MediaHeader with optional snake_case properties.
struct MediaHeader {
    var header_id: Int?
    var itag: Int?
    var xtags: String?
    var format_id: Misc_FormatId?
    var is_init_seg: Bool?
    var sequence_number: Int?
    var duration_ms: String?
    var start_ms: String?
    var content_length: String?
    var time_range: TimeRange?
    var start_range: String?

    static let decoder = ProtobufDecoder<MediaHeader> { data in
        let proto = try VideoStreaming_MediaHeader(serializedBytes: data)
        return MediaHeader(proto: proto)
    }

    init(proto: VideoStreaming_MediaHeader) {
        self.header_id = proto.hasHeaderID ? Int(proto.headerID) : nil
        self.itag = proto.hasItag ? Int(proto.itag) : nil
        self.xtags = proto.hasXtags ? proto.xtags : nil
        self.format_id = proto.hasFormatID ? proto.formatID : nil
        self.is_init_seg = proto.hasIsInitSeg ? proto.isInitSeg : nil
        self.sequence_number = proto.hasSequenceNumber ? Int(proto.sequenceNumber) : nil
        self.duration_ms = proto.hasDurationMs ? String(proto.durationMs) : nil
        self.start_ms = proto.hasStartMs ? String(proto.startMs) : nil
        self.content_length = proto.hasContentLength ? String(proto.contentLength) : nil
        self.time_range = proto.hasTimeRange ? TimeRange(proto: proto.timeRange) : nil
        self.start_range = proto.hasStartRange ? String(proto.startRange) : nil
    }
}

// MARK: - FormatInitializationMetadata wrapper

struct FormatInitializationMetadata {
    var format_id: Misc_FormatId?
    var end_segment_number: String?
    var duration_units: String?
    var duration_timescale: String?
    var mime_type: String?
    var start_range: String?
    var end_range: String?

    static let decoder = ProtobufDecoder<FormatInitializationMetadata> { data in
        let proto = try VideoStreaming_FormatInitializationMetadata(serializedBytes: data)
        return FormatInitializationMetadata(proto: proto)
    }

    init() {}

    init(proto: VideoStreaming_FormatInitializationMetadata) {
        self.format_id = proto.hasFormatID ? proto.formatID : nil
        self.end_segment_number = proto.hasEndSegmentNumber ? String(proto.endSegmentNumber) : nil
        self.mime_type = proto.hasMimeType ? proto.mimeType : nil
        self.duration_units = proto.hasDurationUnits ? String(proto.durationUnits) : nil
        self.duration_timescale = proto.hasDurationTimescale ? String(proto.durationTimescale) : nil
    }
}

// MARK: - NextRequestPolicy wrapper

struct NextRequestPolicy {
    var backoff_time_ms: Double?
    var playback_cookie: VideoStreaming_PlaybackCookie?

    static let decoder = ProtobufDecoder<NextRequestPolicy> { data in
        let proto = try VideoStreaming_NextRequestPolicy(serializedBytes: data)
        return NextRequestPolicy(proto: proto)
    }

    init(proto: VideoStreaming_NextRequestPolicy) {
        self.backoff_time_ms = proto.hasBackoffTimeMs ? Double(proto.backoffTimeMs) : nil
        self.playback_cookie = proto.hasPlaybackCookie ? proto.playbackCookie : nil
    }
}

// MARK: - StreamProtectionStatus wrapper

struct StreamProtectionStatus {
    var status: Int?

    static let decoder = ProtobufDecoder<StreamProtectionStatus> { data in
        let proto = try VideoStreaming_StreamProtectionStatus(serializedBytes: data)
        return StreamProtectionStatus(proto: proto)
    }

    init(proto: VideoStreaming_StreamProtectionStatus) {
        self.status = proto.hasStatus ? Int(proto.status) : nil
    }
}

// MARK: - SabrContextUpdate wrapper

struct SabrContextUpdate {
    var type: Int?
    var value: Data?
    var write_policy: WritePolicy?
    var send_by_default: Bool?

    enum WritePolicy: Equatable {
        case KEEP_EXISTING
        case OVERWRITE
    }

    static let decoder = ProtobufDecoder<SabrContextUpdate> { data in
        let proto = try VideoStreaming_SabrContextUpdate(serializedBytes: data)
        return SabrContextUpdate(proto: proto)
    }

    init(proto: VideoStreaming_SabrContextUpdate) {
        self.type = proto.hasType ? Int(proto.type) : nil
        self.value = proto.hasValue ? proto.value : nil
        self.send_by_default = proto.hasSendByDefault ? proto.sendByDefault : nil
        if proto.hasWritePolicy {
            self.write_policy = proto.writePolicy == .keepExisting ? .KEEP_EXISTING : .OVERWRITE
        }
    }
}

// MARK: - SabrContextSendingPolicy wrapper

struct SabrContextSendingPolicy {
    var start_policy: [Int]
    var stop_policy: [Int]
    var discard_policy: [Int]

    static let decoder = ProtobufDecoder<SabrContextSendingPolicy> { data in
        let proto = try VideoStreaming_SabrContextSendingPolicy(serializedBytes: data)
        return SabrContextSendingPolicy(proto: proto)
    }

    init(proto: VideoStreaming_SabrContextSendingPolicy) {
        self.start_policy = proto.startPolicy.map { Int($0) }
        self.stop_policy = proto.stopPolicy.map { Int($0) }
        self.discard_policy = proto.discardPolicy.map { Int($0) }
    }
}

// MARK: - SabrRedirect wrapper

struct SabrRedirect {
    var url: String?

    static let decoder = ProtobufDecoder<SabrRedirect> { data in
        let proto = try VideoStreaming_SabrRedirect(serializedBytes: data)
        return SabrRedirect(proto: proto)
    }

    init(proto: VideoStreaming_SabrRedirect) {
        self.url = proto.hasURL ? proto.url : nil
    }
}

// MARK: - SabrError wrapper

struct SabrError {
    var code: Int?
    var type: String?

    static let decoder = ProtobufDecoder<SabrError> { data in
        let proto = try VideoStreaming_SabrError(serializedBytes: data)
        return SabrError(proto: proto)
    }

    init(proto: VideoStreaming_SabrError) {
        self.code = proto.hasCode ? Int(proto.code) : nil
        self.type = proto.hasType ? proto.type : nil
    }
}

// MARK: - ReloadPlaybackContext wrapper

struct ReloadPlaybackContext {
    struct ReloadParams {
        var token: String?
    }
    var reload_playback_params: ReloadParams?

    static let decoder = ProtobufDecoder<ReloadPlaybackContext> { data in
        let proto = try VideoStreaming_ReloadPlaybackContext(serializedBytes: data)
        return ReloadPlaybackContext(proto: proto)
    }

    init(proto: VideoStreaming_ReloadPlaybackContext) {
        if proto.hasReloadPlaybackParams {
            self.reload_playback_params = ReloadParams(
                token: proto.reloadPlaybackParams.hasToken ? proto.reloadPlaybackParams.token : nil
            )
        }
    }
}

// MARK: - VideoPlaybackAbrRequest builder

/// Builder that maps to VideoStreaming_VideoPlaybackAbrRequest proto.
struct VideoPlaybackAbrRequest {
    var client_abr_state: AbrState
    var preferred_audio_format_ids: [SabrFormat]
    var preferred_video_format_ids: [SabrFormat]
    var preferred_subtitle_format_ids: [SabrFormat]
    var selected_format_ids: [SabrFormat]
    var video_playback_ustreamer_config: Data?
    var streamer_context: StreamerContext
    var buffered_ranges: [BufferedRange]
    var field1000: [Int]

    static func encode(_ request: VideoPlaybackAbrRequest) -> BinaryEncodingResult {
        var proto = VideoStreaming_VideoPlaybackAbrRequest()
        proto.clientAbrState = request.client_abr_state.proto
        proto.preferredAudioFormatIds = request.preferred_audio_format_ids.map { $0.format_id }
        proto.preferredVideoFormatIds = request.preferred_video_format_ids.map { $0.format_id }
        proto.preferredSubtitleFormatIds = request.preferred_subtitle_format_ids.map { $0.format_id }
        proto.selectedFormatIds = request.selected_format_ids.map { $0.format_id }
        if let config = request.video_playback_ustreamer_config {
            proto.videoPlaybackUstreamerConfig = config
        }
        proto.streamerContext = request.streamer_context.proto
        proto.bufferedRanges = request.buffered_ranges.map { $0.proto }
        return BinaryEncodingResult(proto: proto)
    }
}

struct BinaryEncodingResult {
    private let proto: SwiftProtobuf.Message

    init(proto: SwiftProtobuf.Message) {
        self.proto = proto
    }

    func finish() -> Data {
        return (try? proto.serializedData()) ?? Data()
    }
}

// MARK: - AbrState (ClientAbrState builder)

struct AbrState {
    var player_time_ms: Double = 0
    var audio_track_id: String? = nil
    var playback_rate: Double = 1.0
    var sticky_resolution: Int = 360
    var drc_enabled: Bool = false
    var client_viewport_is_flexible: Bool = false
    var visibility: Int = 1
    var enabled_track_types_bitfield: Int = 0

    var proto: VideoStreaming_ClientAbrState {
        var s = VideoStreaming_ClientAbrState()
        s.playerTimeMs = Int64(player_time_ms)
        s.playbackRate = Float(playback_rate)
        s.stickyResolution = Int32(sticky_resolution)
        s.clientViewportIsFlexible = client_viewport_is_flexible
        s.drcEnabled = drc_enabled
        s.visibility = Int32(visibility)
        s.bandwidthEstimate = 5_000_000
        s.enabledTrackTypesBitfield = Int32(enabled_track_types_bitfield)
        if let atid = audio_track_id { s.audioTrackID = atid }
        return s
    }
}

// MARK: - StreamerContext builder

struct StreamerContext {
    var sabr_contexts: [SabrContextUpdate] = []
    var unsent_sabr_contexts: [Int] = []
    var po_token: Data? = nil
    var playback_cookie: Data? = nil
    var client_info: ClientInfo? = nil

    var proto: VideoStreaming_StreamerContext {
        var sc = VideoStreaming_StreamerContext()
        if let pt = po_token { sc.poToken = pt }
        if let pc = playback_cookie { sc.playbackCookie = pc }
        if let ci = client_info { sc.clientInfo = ci }
        sc.sabrContexts = sabr_contexts.compactMap { ctx -> VideoStreaming_StreamerContext.SabrContext? in
            guard let t = ctx.type, let v = ctx.value else { return nil }
            var sabrCtx = VideoStreaming_StreamerContext.SabrContext()
            sabrCtx.type = Int32(t)
            sabrCtx.value = v
            return sabrCtx
        }
        sc.unsentSabrContexts = unsent_sabr_contexts.map { Int32($0) }
        return sc
    }
}

// MARK: - BufferedRange builder

struct BufferedRange {
    var format_id: Misc_FormatId?
    var duration_ms: String?
    var start_time_ms: String?
    var start_segment_index: Int?
    var end_segment_index: Int?
    var time_range: TimeRange?

    init(
        format_id: Misc_FormatId? = nil,
        duration_ms: String? = nil,
        start_time_ms: String? = nil,
        start_segment_index: Int? = nil,
        end_segment_index: Int? = nil,
        time_range: TimeRange? = nil
    ) {
        self.format_id = format_id
        self.duration_ms = duration_ms
        self.start_time_ms = start_time_ms
        self.start_segment_index = start_segment_index
        self.end_segment_index = end_segment_index
        self.time_range = time_range
    }

    var proto: VideoStreaming_BufferedRange {
        var br = VideoStreaming_BufferedRange()
        if let fid = format_id { br.formatID = fid }
        if let dms = duration_ms.flatMap({ Int64($0) }) { br.durationMs = dms }
        if let stms = start_time_ms.flatMap({ Int64($0) }) { br.startTimeMs = stms }
        if let ssi = start_segment_index { br.startSegmentIndex = Int32(ssi) }
        if let esi = end_segment_index { br.endSegmentIndex = Int32(esi) }
        if let tr = time_range { br.timeRange = tr.proto }
        return br
    }
}

// MARK: - max_int32_value constant

let max_int32_value: String = "2147483647"
