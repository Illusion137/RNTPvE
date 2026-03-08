import Foundation

// MARK: - Segment

/// A media segment from a SABR stream.
struct Segment {
    /// Format key identifying which format this segment belongs to.
    var format_id_key: String = ""
    /// Segment sequence number (0 = init segment).
    var segment_number: Int = 0
    /// Duration of this segment in milliseconds (as string).
    var duration_ms: String = "0"
    /// The media header associated with this segment.
    var media_header: MediaHeader
    /// Raw media data chunks.
    var buffered_chunks: [Data] = []

    // Used by UMP processor path
    var header_id: Int? { return media_header.header_id }
    var last_chunk_size: Int = 0

    init(format_id_key: String = "", segment_number: Int = 0, duration_ms: String = "0", media_header: MediaHeader, buffered_chunks: [Data] = []) {
        self.format_id_key = format_id_key
        self.segment_number = segment_number
        self.duration_ms = duration_ms
        self.media_header = media_header
        self.buffered_chunks = buffered_chunks
    }
}
