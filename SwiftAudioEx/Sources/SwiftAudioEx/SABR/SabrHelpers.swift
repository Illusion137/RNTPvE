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
