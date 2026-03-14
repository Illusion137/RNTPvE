import XCTest
@testable import SwiftAudioEx

final class SabrFormatParsingTests: XCTestCase {

    // Sample input matching the shape the user passes from JS (itag 140 audio format).
    private let sampleDict: [String: Any] = [
        "itag": 140,
        "lastModified": "1744730265913521",
        "bitrate": 130620,
        "averageBitrate": 129137,
        "approxDurationMs": 173280,
        "audioQuality": "AUDIO_QUALITY_MEDIUM",
        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
        "quality": "tiny",
        "isDrc": false,
        "isDubbed": true,
        "isAutoDubbed": false,
        "isDescriptive": false,
        "isSecondary": true,
        "isOriginal": false,
        "language": "en",
        "contentLength": 2818497,
    ]

    func testBasicFieldsParsed() {
        guard let fmt = SabrFormat(dictionary: sampleDict) else {
            XCTFail("SabrFormat init failed")
            return
        }
        XCTAssertEqual(fmt.itag, 140)
        XCTAssertEqual(fmt.last_modified, "1744730265913521")
        XCTAssertEqual(fmt.bitrate, 130620)
        XCTAssertEqual(fmt.average_bitrate, 129137)
        XCTAssertEqual(fmt.approx_duration_ms, 173280)
        XCTAssertEqual(fmt.audio_quality, "AUDIO_QUALITY_MEDIUM")
        XCTAssertEqual(fmt.mime_type, "audio/mp4; codecs=\"mp4a.40.2\"")
        XCTAssertEqual(fmt.quality, "tiny")
        XCTAssertEqual(fmt.language, "en")
        XCTAssertEqual(fmt.content_length, "2818497")
    }

    func testBoolFieldsParsed() {
        guard let fmt = SabrFormat(dictionary: sampleDict) else {
            XCTFail("SabrFormat init failed")
            return
        }
        XCTAssertEqual(fmt.is_drc, false)
        XCTAssertEqual(fmt.is_dubbed, true)
        XCTAssertEqual(fmt.is_auto_dubbed, false)
        XCTAssertEqual(fmt.is_descriptive, false)
        XCTAssertEqual(fmt.is_secondary, true)
        XCTAssertEqual(fmt.is_original, false)
    }

    func testMissingBoolFieldsAreNil() {
        // When the JS input omits bool fields they must be nil, not false.
        let minimal: [String: Any] = [
            "itag": 140,
            "bitrate": 100,
        ]
        guard let fmt = SabrFormat(dictionary: minimal) else {
            XCTFail("SabrFormat init failed for minimal dict")
            return
        }
        XCTAssertNil(fmt.is_dubbed)
        XCTAssertNil(fmt.is_auto_dubbed)
        XCTAssertNil(fmt.is_descriptive)
        XCTAssertNil(fmt.is_secondary)
        XCTAssertNil(fmt.is_original)
        XCTAssertNil(fmt.is_drc)
    }

    func testMissingItagReturnsNil() {
        var dict = sampleDict
        dict.removeValue(forKey: "itag")
        XCTAssertNil(SabrFormat(dictionary: dict))
    }

    func testFormatIdBuiltCorrectly() {
        guard let fmt = SabrFormat(dictionary: sampleDict) else {
            XCTFail("SabrFormat init failed")
            return
        }
        let fid = fmt.format_id
        XCTAssertEqual(fid.itag, 140)
        XCTAssertEqual(fid.lastModified, 1744730265913521)
        XCTAssertEqual(fid.xtags, "")
    }
}
