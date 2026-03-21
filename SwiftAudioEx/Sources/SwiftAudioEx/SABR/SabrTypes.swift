import Foundation

// MARK: - FetchFunction

public typealias FetchFunction = (URLRequest) async throws -> (Data, URLResponse)

// MARK: - SabrFormat

/// A YouTube SABR format descriptor, combining proto FormatId fields with extra metadata.
public struct SabrFormat {
    public var itag: Int32 = 0
    public var last_modified: String = ""
    public var xtags: String? = nil
    public var width: Int? = nil
    public var height: Int? = nil
    public var content_length: String? = nil
    public var audio_track_id: String? = nil
    public var mime_type: String? = nil
    public var is_drc: Bool? = nil
    public var quality: String? = nil
    public var quality_label: String? = nil
    public var average_bitrate: Int? = nil
    public var bitrate: Int = 0
    public var audio_quality: String? = nil
    public var approx_duration_ms: Int = 0
    public var language: String? = nil
    public var is_dubbed: Bool? = nil
    public var is_auto_dubbed: Bool? = nil
    public var is_descriptive: Bool? = nil
    public var is_secondary: Bool? = nil
    public var is_original: Bool? = nil

    /// Convert to Misc_FormatId proto for use in ABR request proto.
    var format_id: Misc_FormatId {
        var fid = Misc_FormatId()
        fid.itag = itag
        fid.xtags = xtags ?? ""
        if let lm = UInt64(last_modified) { fid.lastModified = lm }
        return fid
    }

    /// Initialize from a dictionary (from JS bridge).
    public init() {}

    public init?(dictionary: [String: Any]) {
        guard let itag = dictionary["itag"] as? Int else { return nil }
        self.itag = Int32(itag)
        self.last_modified = dictionary["lastModified"] as? String ?? ""
        self.xtags = dictionary["xtags"] as? String
        self.width = dictionary["width"] as? Int
        self.height = dictionary["height"] as? Int
        self.content_length = (dictionary["contentLength"] as? Int).map { String($0) }
        self.audio_track_id = dictionary["audioTrackId"] as? String
        self.mime_type = dictionary["mimeType"] as? String
        self.is_drc = dictionary["isDrc"] as? Bool
        self.quality = dictionary["quality"] as? String
        self.quality_label = dictionary["qualityLabel"] as? String
        self.average_bitrate = dictionary["averageBitrate"] as? Int
        self.bitrate = dictionary["bitrate"] as? Int ?? 0
        self.audio_quality = dictionary["audioQuality"] as? String
        self.approx_duration_ms = dictionary["approxDurationMs"] as? Int ?? 0
        self.language = dictionary["language"] as? String
        self.is_dubbed = dictionary["isDubbed"] as? Bool
        self.is_auto_dubbed = dictionary["isAutoDubbed"] as? Bool
        self.is_descriptive = dictionary["isDescriptive"] as? Bool
        self.is_secondary = dictionary["isSecondary"] as? Bool
        self.is_original = dictionary["isOriginal"] as? Bool
    }
}

// MARK: - SabrStreamConfig

public struct SabrStreamConfig {
    public var server_abr_streaming_url: String? = nil
    public var video_playback_ustreamer_config: String? = nil
    /// Internal — `VideoStreaming_StreamerContext.ClientInfo` is not a public type.
    var client_info: VideoStreaming_StreamerContext.ClientInfo? = nil
    public var po_token: String? = nil
    public var duration_ms: Double? = nil
    public var formats: [SabrFormat]? = nil
    public var fetch: FetchFunction? = nil
    public var cookie: String? = nil

    public init() {}

    public init(
        server_abr_streaming_url: String? = nil,
        video_playback_ustreamer_config: String? = nil,
        po_token: String? = nil,
        duration_ms: Double? = nil,
        formats: [SabrFormat]? = nil,
        fetch: FetchFunction? = nil,
        client_name: Int32? = nil,
        client_version: String? = nil,
        cookie: String? = nil
    ) {
        self.server_abr_streaming_url = server_abr_streaming_url
        self.video_playback_ustreamer_config = video_playback_ustreamer_config
        self.po_token = po_token
        self.duration_ms = duration_ms
        self.formats = formats
        self.fetch = fetch
        self.cookie = cookie
        if let cn = client_name {
            var ci = VideoStreaming_StreamerContext.ClientInfo()
            ci.clientName = cn
            ci.clientVersion = client_version ?? ""
            self.client_info = ci
        }
    }
}

// MARK: - SabrPlaybackOptions

struct SabrPlaybackOptions {
    var video_format: SabrFormat? = nil
    var audio_format: SabrFormat? = nil
    var video_quality: String? = nil
    var audio_quality: String? = nil
    var audio_language: String? = nil
    var prefer_web_m: Bool? = nil
    var prefer_h264: Bool? = nil
    var prefer_mp4: Bool? = nil
    var prefer_opus: Bool? = nil
    /// EnabledTrackTypes raw value: 0=video_and_audio, 1=audio_only, 2=video_only
    var enabled_track_types: Int? = nil
    var max_retries: Int? = nil
    var stall_detection_ms: Double? = nil
    var state: SabrStreamState? = nil
    /// Initial playback position in milliseconds sent to the server as player_time_ms in AbrState.
    /// Tells the server to start sending segments from this position.
    var start_time_ms: Double? = nil

    init() {}

    init(enabled_track_types: Int) {
        self.enabled_track_types = enabled_track_types
    }
}

// MARK: - FormatOptions (internal, used by choose_format)

struct FormatOptions {
    var quality: String? = nil
    var language: String? = nil
    var prefer_web_m: Bool? = nil
    var prefer_h264: Bool? = nil
    var prefer_mp4: Bool? = nil
    var prefer_opus: Bool? = nil
    var is_audio: Bool = false
}

// MARK: - EnabledTrackTypes

struct EnabledTrackTypes {
    static let video_and_audio = 0
    static let audio_only = 1
    static let video_only = 2
}

// MARK: - ClientInfo typealias

typealias ClientInfo = VideoStreaming_StreamerContext.ClientInfo

// MARK: - SabrStreamError

enum SabrStreamError: Error, LocalizedError {
    case main_format_not_initialized
    case no_formats_available
    case max_retries_exceeded
    case stream_stalled
    case invalid_duration
    case no_suitable_formats
    case no_valid_parts
    case no_media_parts
    case missing_ustreamer_config
    case missing_client_info
    case missing_streaming_url
    case invalid_url
    case invalid_response
    case server_error(status: Int)
    case unexpected_content_type(String)

    var errorDescription: String? {
        switch self {
        case .main_format_not_initialized: return "Main format not initialized"
        case .no_formats_available: return "No formats available"
        case .max_retries_exceeded: return "Maximum retries exceeded"
        case .stream_stalled: return "Stream stalled"
        case .invalid_duration: return "Invalid duration"
        case .no_suitable_formats: return "No suitable formats found"
        case .no_valid_parts: return "No valid UMP parts in response"
        case .no_media_parts: return "No media parts in response"
        case .missing_ustreamer_config: return "Missing ustreamer config"
        case .missing_client_info: return "Missing client info"
        case .missing_streaming_url: return "Missing streaming URL"
        case .invalid_url: return "Invalid URL"
        case .invalid_response: return "Invalid response"
        case .server_error(let status): return "Server error: HTTP \(status)"
        case .unexpected_content_type(let ct): return "Unexpected content type: \(ct)"
        }
    }
}

// MARK: - UMPPartId

/// Maps friendly names to VideoStreaming_UMPPartId raw values.
struct UMPPartId {
    static let FORMAT_INITIALIZATION_METADATA = VideoStreaming_UMPPartId.formatInitializationMetadata.rawValue
    static let NEXT_REQUEST_POLICY = VideoStreaming_UMPPartId.nextRequestPolicy.rawValue
    static let SABR_ERROR = VideoStreaming_UMPPartId.sabrError.rawValue
    static let SABR_REDIRECT = VideoStreaming_UMPPartId.sabrRedirect.rawValue
    static let SABR_CONTEXT_UPDATE = VideoStreaming_UMPPartId.sabrContextUpdate.rawValue
    static let SABR_CONTEXT_SENDING_POLICY = VideoStreaming_UMPPartId.sabrContextSendingPolicy.rawValue
    static let SNACKBAR_MESSAGE = VideoStreaming_UMPPartId.snackbarMessage.rawValue
    static let STREAM_PROTECTION_STATUS = VideoStreaming_UMPPartId.streamProtectionStatus.rawValue
    static let RELOAD_PLAYER_RESPONSE = VideoStreaming_UMPPartId.reloadPlayerResponse.rawValue
    static let MEDIA_HEADER = VideoStreaming_UMPPartId.mediaHeader.rawValue
    static let MEDIA = VideoStreaming_UMPPartId.media.rawValue
    static let MEDIA_END = VideoStreaming_UMPPartId.mediaEnd.rawValue
}

// MARK: - ProtobufDecoder

struct ProtobufDecoder<T> {
    let decode: (Data) throws -> T
}
