import Foundation

// MARK: - choose_format

/// Selects the best format matching the given options.
func choose_format(
    _ formats: [SabrFormat],
    _ preferred: SabrFormat?,
    options: FormatOptions
) -> SabrFormat? {
    guard !formats.isEmpty else { return nil }

    if let preferred = preferred { return preferred }

    // Filter by media type
    var candidates = formats.filter { format in
        guard let mt = format.mime_type else { return false }
        return options.is_audio ? mt.contains("audio") : mt.contains("video")
    }

    guard !candidates.isEmpty else { return nil }

    // WebM/Opus is handled by SabrOpusPlayer (AVAudioEngine + AudioToolbox pipeline).
    // No exclusion needed here; callers opt into WebM via prefer_opus/prefer_web_m.

    // Filter by language
    if let language = options.language {
        let lang_matches = candidates.filter { $0.language == language }
        if !lang_matches.isEmpty { candidates = lang_matches }
    }

    // Filter by quality
    if let quality = options.quality {
        let q = quality.lowercased()
        let qual_matches = candidates.filter { format in
            if options.is_audio {
                return format.audio_quality?.lowercased().contains(q) ?? false
            } else {
                return format.quality_label?.lowercased().contains(q) ?? false
            }
        }
        if !qual_matches.isEmpty { candidates = qual_matches }
    }

    // Codec preference filters
    if options.is_audio {
        if options.prefer_opus == true {
            let opus = candidates.filter { $0.mime_type?.contains("opus") ?? false }
            if !opus.isEmpty { candidates = opus }
        }
    } else {
        if options.prefer_h264 == true {
            let h264 = candidates.filter {
                ($0.mime_type?.contains("mp4") ?? false) && ($0.mime_type?.contains("avc") ?? false)
            }
            if !h264.isEmpty { candidates = h264 }
        }
    }

    // Container preference
    if options.prefer_webm == true {
        let webm = candidates.filter { $0.mime_type?.contains("webm") ?? false }
        if !webm.isEmpty { candidates = webm }
    } else if options.prefer_mp4 == true {
        let mp4 = candidates.filter { $0.mime_type?.contains("mp4") ?? false }
        if !mp4.isEmpty { candidates = mp4 }
    }

    // Sort: audio by bitrate desc, video by height desc
    if options.is_audio {
        return candidates.sorted { $0.bitrate > $1.bitrate }.first
    } else {
        return candidates.sorted { ($0.height ?? 0) > ($1.height ?? 0) }.first
    }
}

// MARK: - get_media_type

func get_media_type(_ format: InitializedFormat) -> String {
    return format.format_initialization_metadata.mime_type?.contains("video") == true ? "video" : "audio"
}

// MARK: - get_total_downloaded_duration

func get_total_downloaded_duration(_ format: InitializedFormat) -> Double {
    return format.downloaded_segments.values.reduce(0.0) { total, segment in
        total + (Double(segment.duration_ms) ?? 0)
    }
}

// MARK: - FormatOptions extension for prefer_webm

extension FormatOptions {
    var prefer_webm: Bool? { return prefer_web_m }
}
