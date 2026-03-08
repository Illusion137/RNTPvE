import Foundation

// MARK: - FormatKeyUtils

struct FormatKeyUtils {

    /// Creates a format key string from itag and xtags.
    static func create_key(itag: Int32?, xtags: String?) -> String {
        return "\(itag ?? 0):\(xtags ?? "")"
    }

    /// Creates a format key from a SabrFormat.
    static func from_format(_ format: SabrFormat?) -> String? {
        guard let format = format else { return nil }
        return create_key(itag: format.itag, xtags: format.xtags)
    }

    /// Creates a format key from a Misc_FormatId.
    static func from_format_id(_ fid: Misc_FormatId?) -> String? {
        guard let fid = fid else { return nil }
        return create_key(itag: fid.itag, xtags: fid.hasXtags ? fid.xtags : nil)
    }

    /// Creates a format key from a MediaHeader.
    static func from_media_header(_ header: MediaHeader) -> String? {
        return create_key(itag: header.itag.map { Int32($0) }, xtags: header.xtags)
    }

    /// Creates a format key from FormatInitializationMetadata.
    static func from_format_initialization_metadata(_ meta: FormatInitializationMetadata) -> String? {
        guard let fid = meta.format_id else { return nil }
        return from_format_id(fid)
    }

    /// Creates a segment cache key.
    static func create_segment_cache_key(media_header: MediaHeader, format: SabrFormat? = nil) -> String {
        if media_header.is_init_seg == true, let format = format {
            let cl = format.content_length ?? ""
            let mt = format.mime_type ?? ""
            return "\(media_header.itag ?? 0):\(media_header.xtags ?? ""):\(cl):\(mt)"
        }
        let sr = media_header.start_range ?? "0"
        return "\(sr)-\(media_header.itag ?? 0)-\(media_header.xtags ?? "")"
    }
}

// MARK: - Free function aliases (for SabrStream compatibility)

func from_format(_ format: SabrFormat?) -> String? {
    return FormatKeyUtils.from_format(format)
}

func from_media_header(_ header: MediaHeader) -> String? {
    return FormatKeyUtils.from_media_header(header)
}

func create_segment_cache_key(media_header: MediaHeader, format: SabrFormat? = nil) -> String {
    return FormatKeyUtils.create_segment_cache_key(media_header: media_header, format: format)
}
