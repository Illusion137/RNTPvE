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

/// Strips the `edts` box (and thus the `elst` edit-list) from every `trak` inside `moov`.
/// YouTube fMP4 audio (itag 140) carries an edit list that iOS misinterprets, causing
/// the reported duration to appear twice the actual length. Removing it lets iOS derive
/// duration purely from the media track header, which is correct.
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
            let inner = fixMoovBoxes(data[data.index(data.startIndex, offsetBy: offset + 8)
                                        ..<
                                        data.index(data.startIndex, offsetBy: end)])
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

private func fixMoovBoxes(_ data: Data) -> Data {
    var result = Data()
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        let end = offset + size
        if type == "trak" {
            let inner = stripEdtsFromTrak(data[data.index(data.startIndex, offsetBy: offset + 8)
                                              ..<
                                              data.index(data.startIndex, offsetBy: end)])
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

private func stripEdtsFromTrak(_ data: Data) -> Data {
    var result = Data()
    var offset = 0
    while offset + 8 <= data.count {
        guard let (type, size) = mp4ReadBox(data, at: offset) else { break }
        let end = offset + size
        if type != "edts" {
            result.append(data[data.index(data.startIndex, offsetBy: offset)
                               ..<
                               data.index(data.startIndex, offsetBy: min(end, data.count))])
        }
        offset = end
    }
    return result
}

/// Returns (fourCC, totalBoxSize) for the MP4 box at `offset`, or nil on malformed data.
private func mp4ReadBox(_ data: Data, at offset: Int) -> (String, Int)? {
    guard offset + 8 <= data.count else { return nil }
    let sizeBE = data[data.index(data.startIndex, offsetBy: offset)
                      ..<
                      data.index(data.startIndex, offsetBy: offset + 4)]
        .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    let size = Int(sizeBE)
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
