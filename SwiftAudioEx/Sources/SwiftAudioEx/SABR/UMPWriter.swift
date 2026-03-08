import Foundation

/// A serialization module that encodes data into the UMP binary format with proper type and size encoding.
class UmpWriter {
    private var composite_buffer: CompositeBuffer

    init(composite_buffer: CompositeBuffer) {
        self.composite_buffer = composite_buffer
    }

    /// Writes a part to the buffer.
    /// - Parameters:
    ///   - part_type: The type of the part.
    ///   - part_data: The data of the part.
    func write(part_type: Int, part_data: Data) {
        let part_size = part_data.count
        write_var_int(value: part_type)
        write_var_int(value: part_size)
        composite_buffer.append(chunk: part_data)
    }

    /// Writes a variable-length integer to the buffer.
    /// - Parameter value: The integer to write.
    private func write_var_int(value: Int) {
        precondition(value >= 0, "VarInt value cannot be negative.")

        if value < 128 {
            composite_buffer.append(chunk: Data([UInt8(value)]))
        } else if value < 16384 {
            composite_buffer.append(chunk: Data([
                UInt8((value & 0x3F) | 0x80),
                UInt8(value >> 6)
            ]))
        } else if value < 2097152 {
            composite_buffer.append(chunk: Data([
                UInt8((value & 0x1F) | 0xC0),
                UInt8((value >> 5) & 0xFF),
                UInt8(value >> 13)
            ]))
        } else if value < 268435456 {
            composite_buffer.append(chunk: Data([
                UInt8((value & 0x0F) | 0xE0),
                UInt8((value >> 4) & 0xFF),
                UInt8((value >> 12) & 0xFF),
                UInt8(value >> 20)
            ]))
        } else {
            var bytes = Data(count: 5)
            bytes[0] = 0xF0
            var little_endian_value = UInt32(value).littleEndian
            withUnsafeBytes(of: &little_endian_value) { ptr in
                bytes.replaceSubrange(1..<5, with: ptr)
            }
            composite_buffer.append(chunk: bytes)
        }
    }
}