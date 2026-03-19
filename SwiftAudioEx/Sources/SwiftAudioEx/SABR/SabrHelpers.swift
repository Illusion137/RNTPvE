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

/// Fixes the `moov` box in a YouTube fMP4 audio init segment so iOS reports the correct duration.
///
/// YouTube itag 140 init segments contain an `edts/elst` edit list whose entries inflate
/// `tkhd.duration` (iOS AVFoundation treats `tkhd.duration` as the authoritative track length).
/// Two corrections are applied to every `trak`:
///   1. The `edts` box is stripped entirely.
///   2. `tkhd.duration` is recomputed from `mdhd.duration` scaled to the movie timescale,
///      so it reflects only the actual encoded samples.
///
/// Only the initialization segment (first chunk, containing ftyp+moov) needs this treatment;
/// subsequent moof+mdat segments are returned unchanged.
func fixMP4InitSegment(_ data: Data) -> Data {
    var result = Data()
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        let end = offset + size
        if type == "moov" {
            let moovContent = data[data.index(data.startIndex, offsetBy: offset + 8)
                                  ..<
                                  data.index(data.startIndex, offsetBy: end)]
            let mvhdTimescale = parseMvhdTimescale(in: moovContent)
            let inner = fixMoovBoxes(moovContent, mvhdTimescale: mvhdTimescale)
            result.append(mp4WriteBox("moov", content: inner))
        } else {
            result.append(data[data.index(data.startIndex, offsetBy: offset)
                               ..<
                               data.index(data.startIndex, offsetBy: min(end, data.count))])
        }
        offset = end
    }
    return result.isEmpty ? data : result
}

private func fixMoovBoxes(_ data: Data, mvhdTimescale: UInt32) -> Data {
    var result = Data()
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        let end = offset + size
        if type == "trak" {
            let inner = fixTrak(data[data.index(data.startIndex, offsetBy: offset + 8)
                                    ..<
                                    data.index(data.startIndex, offsetBy: end)],
                                mvhdTimescale: mvhdTimescale)
            result.append(mp4WriteBox("trak", content: inner))
        } else {
            result.append(data[data.index(data.startIndex, offsetBy: offset)
                               ..<
                               data.index(data.startIndex, offsetBy: min(end, data.count))])
        }
        offset = end
    }
    return result
}

/// Strips `edts` from a trak and patches `tkhd.duration` to match `mdhd.duration` scaled
/// to the movie timescale, eliminating the encoder-delay inflation that iOS reads from the
/// original `tkhd.duration`.
private func fixTrak(_ data: Data, mvhdTimescale: UInt32) -> Data {
    var result = Data()
    var tkhdOffset = -1
    var mdhdTimescale: UInt32 = 0
    var mdhdDuration: UInt64 = 0

    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        let end = offset + size
        let slice = data[data.index(data.startIndex, offsetBy: offset)
                        ..<
                        data.index(data.startIndex, offsetBy: min(end, data.count))]
        if type == "edts" {
            // strip — do not append
        } else if type == "tkhd" {
            tkhdOffset = result.count
            result.append(slice)
        } else if type == "mdia" {
            let mdiaInner = data[data.index(data.startIndex, offsetBy: offset + 8)
                                ..<
                                data.index(data.startIndex, offsetBy: min(end, data.count))]
            (mdhdTimescale, mdhdDuration) = parseMdhd(in: mdiaInner)
            result.append(slice)
        } else {
            result.append(slice)
        }
        offset = end
    }

    if tkhdOffset >= 0, mdhdTimescale > 0, mvhdTimescale > 0 {
        let corrected = mdhdDuration * UInt64(mvhdTimescale) / UInt64(mdhdTimescale)
        patchTkhdDuration(&result, at: tkhdOffset, duration: corrected)
    }

    return result
}

/// Reads `mvhd.timescale` from the moov content slice.
private func parseMvhdTimescale(in data: Data) -> UInt32 {
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        if type == "mvhd" {
            let base = data.startIndex + offset
            guard base + 9 <= data.endIndex else { break }
            let version = data[base + 8]
            // version=0: timescale@20; version=1: timescale@28
            return readU32(data, at: base + (version == 1 ? 28 : 20)) ?? 0
        }
        offset += size
    }
    return 0
}

/// Reads `mdhd.timescale` and `mdhd.duration` from the mdia content slice.
private func parseMdhd(in data: Data) -> (timescale: UInt32, duration: UInt64) {
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        if type == "mdhd" {
            let base = data.startIndex + offset
            guard base + 9 <= data.endIndex else { break }
            let version = data[base + 8]
            if version == 1 {
                // timescale@28 (UInt32), duration@32 (UInt64)
                guard let ts = readU32(data, at: base + 28),
                      let dur = readU64(data, at: base + 32) else { break }
                return (ts, dur)
            } else {
                // timescale@20 (UInt32), duration@24 (UInt32)
                guard let ts  = readU32(data, at: base + 20),
                      let dur = readU32(data, at: base + 24) else { break }
                return (ts, UInt64(dur))
            }
        }
        offset += size
    }
    return (0, 0)
}

/// Overwrites the `duration` field inside a `tkhd` box that starts at `tkhdOffset` in `data`.
private func patchTkhdDuration(_ data: inout Data, at tkhdOffset: Int, duration: UInt64) {
    let base = data.startIndex + tkhdOffset
    guard base + 9 <= data.endIndex else { return }
    let version = data[base + 8]
    if version == 1 {
        // duration is UInt64 at offset 36
        let off = base + 36
        guard off + 8 <= data.endIndex else { return }
        data[off + 0] = UInt8((duration >> 56) & 0xFF)
        data[off + 1] = UInt8((duration >> 48) & 0xFF)
        data[off + 2] = UInt8((duration >> 40) & 0xFF)
        data[off + 3] = UInt8((duration >> 32) & 0xFF)
        data[off + 4] = UInt8((duration >> 24) & 0xFF)
        data[off + 5] = UInt8((duration >> 16) & 0xFF)
        data[off + 6] = UInt8((duration >>  8) & 0xFF)
        data[off + 7] = UInt8( duration        & 0xFF)
    } else {
        // duration is UInt32 at offset 28
        let off = base + 28
        guard off + 4 <= data.endIndex else { return }
        let dur32 = UInt32(min(duration, UInt64(UInt32.max)))
        data[off + 0] = UInt8((dur32 >> 24) & 0xFF)
        data[off + 1] = UInt8((dur32 >> 16) & 0xFF)
        data[off + 2] = UInt8((dur32 >>  8) & 0xFF)
        data[off + 3] = UInt8( dur32        & 0xFF)
    }
}

/// Returns (fourCC, totalBoxSize) for the MP4 box at `offset`, or nil on malformed data.
private func mp4ReadBox(_ data: Data, at offset: Int) -> (String, Int)? {
    guard offset + 8 <= data.count else { return nil }
    let i = data.index(data.startIndex, offsetBy: offset)
    let size = Int(UInt32(data[i]) << 24
                 | UInt32(data[data.index(i, offsetBy: 1)]) << 16
                 | UInt32(data[data.index(i, offsetBy: 2)]) << 8
                 | UInt32(data[data.index(i, offsetBy: 3)]))
    guard size >= 8, offset + size <= data.count else { return nil }
    let typeBytes = data[data.index(data.startIndex, offsetBy: offset + 4)
                         ..<
                         data.index(data.startIndex, offsetBy: offset + 8)]
    let type = String(bytes: typeBytes, encoding: .ascii) ?? "????"
    return (type, size)
}

/// Wraps `content` in a box with the given four-character type code.
private func mp4WriteBox(_ type: String, content: Data) -> Data {
    var box = Data()
    let size = UInt32(content.count + 8).bigEndian
    withUnsafeBytes(of: size) { box.append(contentsOf: $0) }
    box.append(contentsOf: type.utf8.prefix(4))
    box.append(content)
    return box
}

private func readU32(_ data: Data, at index: Data.Index) -> UInt32? {
    guard index + 4 <= data.endIndex else { return nil }
    return UInt32(data[index])     << 24
         | UInt32(data[index + 1]) << 16
         | UInt32(data[index + 2]) <<  8
         | UInt32(data[index + 3])
}

private func readU64(_ data: Data, at index: Data.Index) -> UInt64? {
    guard index + 8 <= data.endIndex else { return nil }
    let hi = UInt64(data[index])     << 56
           | UInt64(data[index + 1]) << 48
           | UInt64(data[index + 2]) << 40
           | UInt64(data[index + 3]) << 32
    let lo = UInt64(data[index + 4]) << 24
           | UInt64(data[index + 5]) << 16
           | UInt64(data[index + 6]) <<  8
           | UInt64(data[index + 7])
    return hi | lo
}
