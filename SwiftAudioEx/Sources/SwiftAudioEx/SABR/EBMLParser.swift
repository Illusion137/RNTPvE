import Foundation

// MARK: - Output types

struct OpusPacket {
    let timestampMs: Double
    let data: Data
}

struct OpusStreamInfo {
    let channelCount: Int
    let sampleRate: Double
    let preSkip: Int
}

// MARK: - EBMLParser

/// Stateful, incremental EBML parser for fragmented WebM.
/// Feed raw `Data` chunks sequentially; collect emitted `OpusPacket`s and
/// the one-time `OpusStreamInfo` from the init chunk.
final class EBMLParser {

    // MARK: - Public outputs

    private(set) var streamInfo: OpusStreamInfo?
    private(set) var packets: [OpusPacket] = []

    // MARK: - Private state

    private var buf = Data()

    /// Nanoseconds-per-timestamp-unit → divide by 1e6 to get ms factor.
    private var timestampScaleMs: Double = 1.0  // default: 1 ms per unit

    private var clusterTimestampMs: Double = 0.0

    // MARK: - EBML element IDs

    private enum ID: UInt64 {
        case ebml           = 0x1A45DFA3
        case segment        = 0x18538067
        case info           = 0x1549A966
        case tracks         = 0x1654AE6B
        case cluster        = 0x1F43B675
        case trackEntry     = 0xAE
        case codecPrivate   = 0x63A2
        case timestampScale = 0x2AD7B1
        case timestamp      = 0xE7       // Cluster Timestamp
        case simpleBlock    = 0xA3
        case blockGroup     = 0xA0
        case block          = 0xA1
    }

    // MARK: - Public API

    func feed(_ data: Data) {
        buf.append(data)
        packets.removeAll()
        var pos = buf.startIndex

        // IDs of master (container) elements whose children we need to parse.
        // For these we descend immediately — we must NOT wait for the full body
        // to be buffered, because Segment can span the entire file.
        let masterIDs: Set<UInt64> = [
            ID.ebml.rawValue, ID.segment.rawValue, ID.info.rawValue,
            ID.tracks.rawValue, ID.cluster.rawValue, ID.trackEntry.rawValue,
            ID.blockGroup.rawValue
        ]

        while pos < buf.endIndex {
            guard let (id, headerLen, bodyLen) = peekElement(at: pos) else { break }
            let bodyStart = pos + headerLen

            // Unknown-size element (master) — enter it
            if bodyLen == nil {
                pos = bodyStart
                continue
            }

            // Known-size master element — descend into children immediately
            // without waiting for the full body to be buffered.
            if masterIDs.contains(id) {
                pos = bodyStart
                continue
            }

            let bodySize = bodyLen!

            // Leaf element — need the full body before we can parse it
            if bodyStart + bodySize > buf.endIndex { break }

            let bodyEnd = bodyStart + bodySize
            let body = buf[bodyStart..<bodyEnd]

            switch id {
            case ID.timestampScale.rawValue:
                let scale = readUInt(body)
                timestampScaleMs = Double(scale) / 1_000_000.0
                pos = bodyEnd

            case ID.codecPrivate.rawValue:
                if streamInfo == nil {
                    streamInfo = parseOpusHeader(body)
                }
                pos = bodyEnd

            case ID.timestamp.rawValue:
                let ts = readUInt(body)
                clusterTimestampMs = Double(ts) * timestampScaleMs
                pos = bodyEnd

            case ID.simpleBlock.rawValue, ID.block.rawValue:
                if let pkt = parseBlock(body) {
                    packets.append(pkt)
                }
                pos = bodyEnd

            default:
                // Unknown / unneeded element — skip body
                pos = bodyEnd
            }
        }

        // Retain only unprocessed bytes
        if pos > buf.startIndex {
            buf = Data(buf[pos...])
        }
    }

    // MARK: - EBML helpers

    /// Returns `(elementID, headerByteLength, bodyByteLength?)`.
    /// Body length is `nil` for unknown-size master elements (size == all 1-bits).
    private func peekElement(at start: Data.Index) -> (UInt64, Int, Int?)? {
        guard start < buf.endIndex else { return nil }
        guard let (id, idLen) = readVInt(at: start, isID: true) else { return nil }
        let sizePos = start + idLen
        guard sizePos < buf.endIndex else { return nil }
        guard let (rawSize, sizeLen) = readVInt(at: sizePos, isID: false) else { return nil }

        let headerLen = idLen + sizeLen

        // All-ones value in a size field means unknown size (master element, stream until next level-1)
        let unknownSize: UInt64 = (1 << (7 * sizeLen)) - 1
        if rawSize == unknownSize {
            return (id, headerLen, nil)
        }

        return (id, headerLen, Int(rawSize))
    }

    /// Decode an EBML variable-length integer.
    /// - `isID`: for element IDs the leading 1-bit is NOT masked off; for sizes it is.
    private func readVInt(at pos: Data.Index, isID: Bool) -> (UInt64, Int)? {
        guard pos < buf.endIndex else { return nil }
        let firstByte = buf[pos]
        guard firstByte != 0 else { return nil }

        // Count leading zeros to find width
        var width = 1
        var mask: UInt8 = 0x80
        while (firstByte & mask) == 0 && width <= 8 {
            width += 1
            mask >>= 1
        }

        guard pos + width <= buf.endIndex else { return nil }

        var value: UInt64 = 0
        for i in 0..<width {
            value = (value << 8) | UInt64(buf[pos + i])
        }

        if !isID {
            // Mask off the width-indicator bit for size fields
            let maskBits: UInt64 = 0x80 >> (width - 1)
            value &= ~(maskBits << (UInt64(width - 1) * 8))
        }

        return (value, width)
    }

    private func readUInt(_ data: Data) -> UInt64 {
        var v: UInt64 = 0
        for byte in data { v = (v << 8) | UInt64(byte) }
        return v
    }

    // MARK: - Opus header parser (https://datatracker.ietf.org/doc/html/rfc7845#section-5.1)

    private func parseOpusHeader(_ data: Data) -> OpusStreamInfo? {
        // Magic signature: "OpusHead" (8 bytes)
        guard data.count >= 19 else { return nil }
        let magic = data[data.startIndex..<data.startIndex+8]
        guard magic.elementsEqual("OpusHead".utf8) else { return nil }

        let base = data.startIndex
        // version: byte 8
        // channel count: byte 9
        let channelCount = Int(data[base + 9])
        // pre-skip: bytes 10-11, little-endian uint16
        let preSkip = Int(data[base + 10]) | (Int(data[base + 11]) << 8)
        // input sample rate: bytes 12-15, little-endian uint32
        let sr = UInt32(data[base + 12])
            | (UInt32(data[base + 13]) << 8)
            | (UInt32(data[base + 14]) << 16)
            | (UInt32(data[base + 15]) << 24)
        let sampleRate = sr > 0 ? Double(sr) : 48000.0

        return OpusStreamInfo(channelCount: channelCount, sampleRate: sampleRate, preSkip: preSkip)
    }

    // MARK: - SimpleBlock / Block parser

    private func parseBlock(_ data: Data) -> OpusPacket? {
        var pos = data.startIndex

        // Track number: EBML VINT
        guard let (_, trackLen) = readVIntInData(data, at: pos) else { return nil }
        pos += trackLen

        // Timestamp delta: 2-byte big-endian int16
        guard pos + 2 <= data.endIndex else { return nil }
        let high = Int16(bitPattern: UInt16(data[pos]) << 8 | UInt16(data[pos + 1]))
        pos += 2

        // Flags: 1 byte
        guard pos + 1 <= data.endIndex else { return nil }
        pos += 1  // skip flags

        // Remainder is the Opus packet
        guard pos < data.endIndex else { return nil }
        let frameData = data[pos...]

        let deltaMs = Double(high) * timestampScaleMs
        let timestampMs = clusterTimestampMs + deltaMs

        return OpusPacket(timestampMs: timestampMs, data: Data(frameData))
    }

    /// Like `readVInt` but works on a `Data` slice with its own index range.
    private func readVIntInData(_ data: Data, at pos: Data.Index) -> (UInt64, Int)? {
        guard pos < data.endIndex else { return nil }
        let firstByte = data[pos]
        guard firstByte != 0 else { return nil }

        var width = 1
        var mask: UInt8 = 0x80
        while (firstByte & mask) == 0 && width <= 8 {
            width += 1
            mask >>= 1
        }

        guard pos + width <= data.endIndex else { return nil }

        var value: UInt64 = 0
        for i in 0..<width {
            value = (value << 8) | UInt64(data[pos + i])
        }

        // Mask off the width-indicator bit (size semantics for track number)
        let maskBits: UInt64 = 0x80 >> (width - 1)
        value &= ~(maskBits << (UInt64(width - 1) * 8))

        return (value, width)
    }
}
