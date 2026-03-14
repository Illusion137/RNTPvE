import XCTest
import SwiftProtobuf
@testable import SwiftAudioEx

final class SabrProtoWrapperTests: XCTestCase {

    // MARK: - StreamerContext: sabrContexts serialization

    func testSabrContextsSerializedIntoProto() throws {
        var ctx = StreamerContext()
        var update = SabrContextUpdate(proto: VideoStreaming_SabrContextUpdate())
        update.type = 5
        update.value = Data([0x01, 0x02, 0x03])
        ctx.sabr_contexts = [update]

        let proto = ctx.proto
        XCTAssertEqual(proto.sabrContexts.count, 1)
        XCTAssertEqual(proto.sabrContexts[0].type, 5)
        XCTAssertEqual(proto.sabrContexts[0].value, Data([0x01, 0x02, 0x03]))
    }

    func testSabrContextsRoundTripThroughSerialization() throws {
        var ctx = StreamerContext()
        var update = SabrContextUpdate(proto: VideoStreaming_SabrContextUpdate())
        update.type = 7
        update.value = Data([0xDE, 0xAD, 0xBE, 0xEF])
        ctx.sabr_contexts = [update]

        let encoded = try ctx.proto.serializedData()
        let decoded = try VideoStreaming_StreamerContext(serializedBytes: encoded)

        XCTAssertEqual(decoded.sabrContexts.count, 1)
        XCTAssertEqual(decoded.sabrContexts[0].type, 7)
        XCTAssertEqual(decoded.sabrContexts[0].value, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testSabrContextWithNilTypeIsDropped() {
        var ctx = StreamerContext()
        var updateMissingType = SabrContextUpdate(proto: VideoStreaming_SabrContextUpdate())
        // type is nil, value is set
        updateMissingType.value = Data([0xFF])
        var updateMissingValue = SabrContextUpdate(proto: VideoStreaming_SabrContextUpdate())
        // value is nil, type is set
        updateMissingValue.type = 3

        var updateValid = SabrContextUpdate(proto: VideoStreaming_SabrContextUpdate())
        updateValid.type = 9
        updateValid.value = Data([0xAB])

        ctx.sabr_contexts = [updateMissingType, updateMissingValue, updateValid]
        XCTAssertEqual(ctx.proto.sabrContexts.count, 1,
                       "Only entries with both type and value should be serialized")
        XCTAssertEqual(ctx.proto.sabrContexts[0].type, 9)
    }

    func testMultipleSabrContextsPreserveOrder() throws {
        var ctx = StreamerContext()
        ctx.sabr_contexts = (1...4).map { i -> SabrContextUpdate in
            var u = SabrContextUpdate(proto: VideoStreaming_SabrContextUpdate())
            u.type = i
            u.value = Data([UInt8(i)])
            return u
        }
        let serialized = ctx.proto.sabrContexts
        XCTAssertEqual(serialized.map { Int($0.type) }, [1, 2, 3, 4])
    }

    func testEmptySabrContextsProducesEmptyArray() {
        let ctx = StreamerContext()
        XCTAssertTrue(ctx.proto.sabrContexts.isEmpty)
    }

    // MARK: - FormatInitializationMetadata: duration fields

    func testDurationFieldsMappedFromProto() {
        var proto = VideoStreaming_FormatInitializationMetadata()
        proto.durationUnits = 173280000
        proto.durationTimescale = 1000000

        let wrapper = FormatInitializationMetadata(proto: proto)
        XCTAssertEqual(wrapper.duration_units, "173280000")
        XCTAssertEqual(wrapper.duration_timescale, "1000000")
    }

    func testDurationFieldsNilWhenNotSetInProto() {
        let proto = VideoStreaming_FormatInitializationMetadata()
        let wrapper = FormatInitializationMetadata(proto: proto)
        XCTAssertNil(wrapper.duration_units)
        XCTAssertNil(wrapper.duration_timescale)
    }

    func testDurationUnitsOnlySet() {
        var proto = VideoStreaming_FormatInitializationMetadata()
        proto.durationUnits = 44100
        let wrapper = FormatInitializationMetadata(proto: proto)
        XCTAssertEqual(wrapper.duration_units, "44100")
        XCTAssertNil(wrapper.duration_timescale)
    }
}
