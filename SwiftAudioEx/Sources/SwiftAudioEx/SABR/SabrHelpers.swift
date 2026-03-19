import Foundation

// MARK: - base64_to_u8

/// Decodes a URL-safe base64 string to Data. Returns empty Data if decoding fails.
func base64_to_u8(_ string: String) -> Data {
    var base64 = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: base64) ?? Data()
}

/// Optional-safe wrapper — returns nil if input is nil.
func base64_to_u8_optional(_ string: String?) -> Data? {
    guard let string = string else { return nil }
    let result = base64_to_u8(string)
    return result.isEmpty ? nil : result
}

// MARK: - concatenate_chunks

/// Concatenates an array of Data chunks into one contiguous Data.
func concatenate_chunks(_ chunks: [Data]) -> Data {
    var result = Data()
    result.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
    for chunk in chunks { result.append(chunk) }
    return result
}

// MARK: - default_fetch

/// Default URLSession-based fetch function for SABR requests.
let default_fetch: FetchFunction = { request in
    return try await URLSession.shared.data(for: request)
}

// MARK: - wait

/// Async sleep helper.
func wait(ms: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
}

// MARK: - is_google_video_url

func is_google_video_url(_ url: URL) -> Bool {
    guard let host = url.host else { return false }
    return host.contains("googlevideo.com") || host.contains("youtube.com") || host.contains("ytimg.com")
}

// MARK: - fixMP4InitSegment

/// Fixes the initialization segment of a YouTube fMP4 audio stream so that AVFoundation
/// reports the correct duration.
///
/// YouTube fMP4 streams carry two duration-related problems:
///   1. An `edts/elst` edit list with a silent pre-roll entry (media_time = -1) that causes
///      AVFoundation to add the pre-roll duration to the reported total, yielding ~2× the
///      actual length.
///   2. `tkhd.duration` is set to the sum of all elst `segment_duration` values (pre-roll +
///      content), so simply removing `edts` still leaves the wrong value in `tkhd`.
///
/// Fix: for every `trak` inside `moov`
///   • strip the `edts` box entirely, and
///   • rewrite `tkhd.duration` to the correct value derived from
///     `mdhd.duration / mdhd.timescale * mvhd.timescale`.
///
/// Only the initialization segment (first chunk, containing ftyp + moov) needs this
/// treatment; subsequent moof + mdat segments are passed through unchanged.
func fixMP4InitSegment(_ data: Data) -> Data {
    guard let mvhdTimescale = findMvhdTimescale(in: data) else { return data }

    var result = Data()
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        if type == "moov" {
            let body = data.subdata(in: (offset + 8) ..< (offset + size))
            result.append(mp4WriteBox("moov", content: fixMoov(body, mvhdTimescale: mvhdTimescale)))
        } else {
            result.append(data.subdata(in: offset ..< (offset + size)))
        }
        offset += size
    }
    return result.isEmpty ? data : result
}

// MARK: - Box traversal

private func findMvhdTimescale(in data: Data) -> UInt32? {
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        if type == "moov" {
            return findMvhdTimescale(inMoov: data.subdata(in: (offset + 8) ..< (offset + size)))
        }
        offset += size
    }
    return nil
}

private func findMvhdTimescale(inMoov data: Data) -> UInt32? {
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        if type == "mvhd" {
            // Body layout (after 8-byte size+type header):
            //   [0]     version (1 byte)
            //   [1-3]   flags (3 bytes)
            //   v0: creation(4) + modification(4) + timescale(4) → timescale at body[12]
            //   v1: creation(8) + modification(8) + timescale(4) → timescale at body[20]
            let body = data.subdata(in: (offset + 8) ..< (offset + size))
            guard body.count >= 4 else { return nil }
            let tsOff = body[0] == 1 ? 20 : 12
            guard body.count >= tsOff + 4 else { return nil }
            return readU32(body, at: tsOff)
        }
        offset += size
    }
    return nil
}

private func fixMoov(_ data: Data, mvhdTimescale: UInt32) -> Data {
    var result = Data()
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        if type == "trak" {
            let body = data.subdata(in: (offset + 8) ..< (offset + size))
            result.append(mp4WriteBox("trak", content: fixTrak(body, mvhdTimescale: mvhdTimescale)))
        } else {
            result.append(data.subdata(in: offset ..< (offset + size)))
        }
        offset += size
    }
    return result
}

private func fixTrak(_ data: Data, mvhdTimescale: UInt32) -> Data {
    let correctDuration = findCorrectDuration(inTrak: data, mvhdTimescale: mvhdTimescale)

    var result = Data()
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        switch type {
        case "edts":
            break  // strip
        case "tkhd":
            var box = data.subdata(in: offset ..< (offset + size))
            if let dur = correctDuration { fixTkhdDuration(&box, newDuration: dur) }
            result.append(box)
        default:
            result.append(data.subdata(in: offset ..< (offset + size)))
        }
        offset += size
    }
    return result
}

/// Derives the correct track duration in movie timescale from mdhd inside trak.
private func findCorrectDuration(inTrak data: Data, mvhdTimescale: UInt32) -> UInt64? {
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        if type == "mdia" {
            let body = data.subdata(in: (offset + 8) ..< (offset + size))
            if let (dur, ts) = findMdhd(inMdia: body), ts > 0 {
                return UInt64(round(Double(dur) / Double(ts) * Double(mvhdTimescale)))
            }
        }
        offset += size
    }
    return nil
}

private func findMdhd(inMdia data: Data) -> (duration: UInt64, timescale: UInt32)? {
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        if type == "mdhd" {
            // Body layout (after 8-byte size+type header):
            //   [0]     version (1 byte)
            //   [1-3]   flags (3 bytes)
            //   v0: creation(4) + modification(4) + timescale(4) + duration(4)
            //         → timescale at body[12], duration at body[16]
            //   v1: creation(8) + modification(8) + timescale(4) + duration(8)
            //         → timescale at body[20], duration at body[24]
            let body = data.subdata(in: (offset + 8) ..< (offset + size))
            guard body.count >= 4 else { return nil }
            if body[0] == 1 {
                guard body.count >= 32 else { return nil }  // 24+8
                return (readU64(body, at: 24), readU32(body, at: 20))
            } else {
                guard body.count >= 20 else { return nil }  // 16+4
                return (UInt64(readU32(body, at: 16)), readU32(body, at: 12))
            }
        }
        offset += size
    }
    return nil
}

/// Rewrites the duration field inside a tkhd box (which includes the 8-byte header).
private func fixTkhdDuration(_ data: inout Data, newDuration: UInt64) {
    // Layout (full box including size+type header):
    //   [0-3]  size, [4-7] type, [8] version, [9-11] flags
    //   v0: creation(4)+modification(4)+trackId(4)+reserved(4)+duration(4) → duration at [28]
    //   v1: creation(8)+modification(8)+trackId(4)+reserved(4)+duration(8) → duration at [36]
    guard data.count >= 12 else { return }
    if data[8] == 1 {
        guard data.count >= 44 else { return }
        writeU64(&data, at: 36, value: newDuration)
    } else {
        guard data.count >= 32 else { return }
        writeU32(&data, at: 28, value: UInt32(min(newDuration, UInt64(UInt32.max))))
    }
}

// MARK: - MP4 box I/O

private func mp4ReadBox(_ data: Data, at offset: Int) -> (String, Int)? {
    guard offset + 8 <= data.count else { return nil }
    let size = Int(readU32(data, at: offset))
    guard size >= 8, offset + size <= data.count else { return nil }
    guard let type = String(bytes: data.subdata(in: (offset + 4) ..< (offset + 8)), encoding: .ascii) else { return nil }
    return (type, size)
}

private func mp4WriteBox(_ type: String, content: Data) -> Data {
    var box = Data()
    let size = UInt32(content.count + 8).bigEndian
    withUnsafeBytes(of: size) { box.append(contentsOf: $0) }
    box.append(contentsOf: type.utf8.prefix(4))
    box.append(content)
    return box
}

// MARK: - Byte helpers

private func readU32(_ data: Data, at offset: Int) -> UInt32 {
    return UInt32(data[offset])     << 24
         | UInt32(data[offset + 1]) << 16
         | UInt32(data[offset + 2]) << 8
         | UInt32(data[offset + 3])
}

private func readU64(_ data: Data, at offset: Int) -> UInt64 {
    return UInt64(data[offset])     << 56
         | UInt64(data[offset + 1]) << 48
         | UInt64(data[offset + 2]) << 40
         | UInt64(data[offset + 3]) << 32
         | UInt64(data[offset + 4]) << 24
         | UInt64(data[offset + 5]) << 16
         | UInt64(data[offset + 6]) << 8
         | UInt64(data[offset + 7])
}

private func writeU32(_ data: inout Data, at offset: Int, value: UInt32) {
    data[offset]     = UInt8(value >> 24)
    data[offset + 1] = UInt8((value >> 16) & 0xFF)
    data[offset + 2] = UInt8((value >> 8)  & 0xFF)
    data[offset + 3] = UInt8(value & 0xFF)
}

private func writeU64(_ data: inout Data, at offset: Int, value: UInt64) {
    data[offset]     = UInt8(value >> 56)
    data[offset + 1] = UInt8((value >> 48) & 0xFF)
    data[offset + 2] = UInt8((value >> 40) & 0xFF)
    data[offset + 3] = UInt8((value >> 32) & 0xFF)
    data[offset + 4] = UInt8((value >> 24) & 0xFF)
    data[offset + 5] = UInt8((value >> 16) & 0xFF)
    data[offset + 6] = UInt8((value >> 8)  & 0xFF)
    data[offset + 7] = UInt8(value & 0xFF)
}
