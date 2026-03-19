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
/// YouTube init segments contain an `edts/elst` edit list that trims playback to the audible
/// portion, but `tkhd.duration` and `mvhd.duration` are wrong. This function replaces the `edts`
/// with a fresh one whose `elst.segment_duration` equals `durationMs`, and patches `tkhd.duration`
/// and `mvhd.duration` to match. `mdhd.duration` is left untouched (it correctly reflects the
/// total encoded sample count). When `durationMs` is 0 only `tkhd`/`mvhd` patching is skipped.
///
/// Only the initialization segment (first chunk, containing ftyp+moov) needs this treatment;
/// subsequent moof+mdat segments are returned unchanged.
func fixMP4InitSegment(_ data: Data, durationMs: Double = 0) -> Data {
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
            let inner = fixMoovBoxes(moovContent, mvhdTimescale: mvhdTimescale, durationMs: durationMs)
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

private func fixMoovBoxes(_ data: Data, mvhdTimescale: UInt32, durationMs: Double) -> Data {
    var result = Data()
    var mvhdOffset = -1
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        let end = offset + size
        if type == "trak" {
            let inner = fixTrak(data[data.index(data.startIndex, offsetBy: offset + 8)
                                    ..<
                                    data.index(data.startIndex, offsetBy: end)],
                                mvhdTimescale: mvhdTimescale,
                                durationMs: durationMs)
            result.append(mp4WriteBox("trak", content: inner))
        } else {
            if type == "mvhd" { mvhdOffset = result.count }
            result.append(data[data.index(data.startIndex, offsetBy: offset)
                               ..<
                               data.index(data.startIndex, offsetBy: min(end, data.count))])
        }
        offset = end
    }
    if durationMs > 0, mvhdOffset >= 0, mvhdTimescale > 0 {
        let dur = UInt64((durationMs * Double(mvhdTimescale) / 1000.0).rounded())
        patchMvhdDuration(&result, at: mvhdOffset, duration: dur)
    }
    return result
}

/// Replaces the `edts` in a trak with a fresh one specifying `durationMs`, and patches
/// `tkhd.duration` to match. `mdhd.duration` is intentionally left untouched.
private func fixTrak(_ data: Data, mvhdTimescale: UInt32, durationMs: Double) -> Data {
    var result = Data()
    var tkhdOffset = -1
    var edtsWritten = false

    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        let end = offset + size
        let slice = data[data.index(data.startIndex, offsetBy: offset)
                        ..<
                        data.index(data.startIndex, offsetBy: min(end, data.count))]
        if type == "edts" {
            // strip old (wrong) edts — replacement inserted before mdia below
        } else if type == "tkhd" {
            tkhdOffset = result.count
            result.append(slice)
        } else if type == "mdia" {
            if durationMs > 0, !edtsWritten {
                result.append(makeEdts(durationMs: durationMs, mvhdTimescale: mvhdTimescale))
                edtsWritten = true
            }
            result.append(slice)
        } else {
            result.append(slice)
        }
        offset = end
    }

    if durationMs > 0, tkhdOffset >= 0, mvhdTimescale > 0 {
        let dur = UInt64((durationMs * Double(mvhdTimescale) / 1000.0).rounded())
        patchTkhdDuration(&result, at: tkhdOffset, duration: dur)
    }

    return result
}

/// Builds a minimal version-0 `edts` box with a single `elst` entry whose
/// `segment_duration` equals `durationMs` (in movie timescale units).
private func makeEdts(durationMs: Double, mvhdTimescale: UInt32) -> Data {
    let segDur = UInt32((durationMs * Double(mvhdTimescale) / 1000.0).rounded())
    var elstContent = Data()
    elstContent.append(contentsOf: [0, 0, 0, 0])          // version=0, flags=0
    elstContent.append(contentsOf: [0, 0, 0, 1])          // entry_count = 1
    elstContent.append(UInt8((segDur >> 24) & 0xFF))      // segment_duration
    elstContent.append(UInt8((segDur >> 16) & 0xFF))
    elstContent.append(UInt8((segDur >>  8) & 0xFF))
    elstContent.append(UInt8( segDur        & 0xFF))
    elstContent.append(contentsOf: [0, 0, 0, 0])          // media_time = 0
    elstContent.append(contentsOf: [0, 1, 0, 0])          // media_rate = 1.0 (16.16 fixed)
    return mp4WriteBox("edts", content: mp4WriteBox("elst", content: elstContent))
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

/// Overwrites the `duration` field inside an `mvhd` box that starts at `mvhdOffset` in `data`.
private func patchMvhdDuration(_ data: inout Data, at mvhdOffset: Int, duration: UInt64) {
    let base = data.startIndex + mvhdOffset
    guard base + 9 <= data.endIndex else { return }
    let version = data[base + 8]
    if version == 1 {
        // duration is UInt64 at offset 32
        let off = base + 32
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
        // duration is UInt32 at offset 24
        let off = base + 24
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
