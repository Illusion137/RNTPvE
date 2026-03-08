class Part {
    var type: Int
    var size: Int
    var data: CompositeBuffer

    init(type: Int, size: Int, data: CompositeBuffer) {
        self.type = type
        self.size = size
        self.data = data
    }
}

class UmpReader {
    private var composite_buffer: CompositeBuffer

    init(composite_buffer: CompositeBuffer) {
        self.composite_buffer = composite_buffer
    }

    /// Parses parts from the buffer and calls the handler for each complete part.
    /// - Parameters:
    ///   - handle_part: Function called with each complete part.
    /// - Returns: Partial part if parsing is incomplete, nil otherwise.
    func read(handle_part: (Part) -> Void) -> Part? {
        while true {
            var offset = 0

            let (part_type, new_offset) = read_var_int(offset: offset)
            offset = new_offset

            let (part_size, final_offset) = read_var_int(offset: offset)
            offset = final_offset

            if part_type < 0 || part_size < 0 {
                break
            }

            if !composite_buffer.can_read_bytes(position: offset, length: part_size) {
                if !composite_buffer.can_read_bytes(position: offset, length: 1) {
                    break
                }

                return Part(
                    type: part_type,
                    size: part_size,
                    data: composite_buffer
                )
            }

            let split_result = composite_buffer.split(position: offset).remaining_buffer.split(position: part_size)
            offset = 0

            handle_part(Part(
                type: part_type,
                size: part_size,
                data: split_result.extracted_buffer
            ))

            composite_buffer = split_result.remaining_buffer
        }

        return nil
    }

    /// Reads a variable-length integer from the buffer.
    /// - Parameter offset: Position to start reading from.
    /// - Returns: Tuple of (value, new offset) or (-1, offset) if incomplete.
    func read_var_int(offset: Int) -> (Int, Int) {
        var current_offset = offset
        let byte_length: Int

        if composite_buffer.can_read_bytes(position: current_offset, length: 1) {
            let first_byte = composite_buffer.get_uint8(position: current_offset)
            if first_byte < 128 {
                byte_length = 1
            } else if first_byte < 192 {
                byte_length = 2
            } else if first_byte < 224 {
                byte_length = 3
            } else if first_byte < 240 {
                byte_length = 4
            } else {
                byte_length = 5
            }
        } else {
            byte_length = 0
        }

        if byte_length < 1 || !composite_buffer.can_read_bytes(position: current_offset, length: byte_length) {
            return (-1, current_offset)
        }

        let value: Int

        switch byte_length {
        case 1:
            value = Int(composite_buffer.get_uint8(position: current_offset))
            current_offset += 1

        case 2:
            let byte1 = composite_buffer.get_uint8(position: current_offset); current_offset += 1
            let byte2 = composite_buffer.get_uint8(position: current_offset); current_offset += 1
            value = Int(byte1 & 0x3f) + 64 * Int(byte2)

        case 3:
            let byte1 = composite_buffer.get_uint8(position: current_offset); current_offset += 1
            let byte2 = composite_buffer.get_uint8(position: current_offset); current_offset += 1
            let byte3 = composite_buffer.get_uint8(position: current_offset); current_offset += 1
            value = Int(byte1 & 0x1f) + 32 * (Int(byte2) + 256 * Int(byte3))

        case 4:
            let byte1 = composite_buffer.get_uint8(position: current_offset); current_offset += 1
            let byte2 = composite_buffer.get_uint8(position: current_offset); current_offset += 1
            let byte3 = composite_buffer.get_uint8(position: current_offset); current_offset += 1
            let byte4 = composite_buffer.get_uint8(position: current_offset); current_offset += 1
            value = Int(byte1 & 0x0f) + 16 * (Int(byte2) + 256 * (Int(byte3) + 256 * Int(byte4)))

        default:
            let temp_offset = current_offset + 1
            composite_buffer.focus(position: temp_offset)

            if can_read_from_current_chunk(offset: temp_offset, length: 4) {
                let data_view = get_current_data_view()
                let local_offset = temp_offset - composite_buffer.current_chunk_offset
                value = Int(data_view.load(fromByteOffset: local_offset, as: UInt32.self).littleEndian)
            } else {
                let b0 = Int(composite_buffer.get_uint8(position: temp_offset))
                let b1 = Int(composite_buffer.get_uint8(position: temp_offset + 1))
                let b2 = Int(composite_buffer.get_uint8(position: temp_offset + 2))
                let b3 = Int(composite_buffer.get_uint8(position: temp_offset + 3))
                let byte3 = b2 + 256 * b3
                value = b0 + 256 * (b1 + 256 * byte3)
            }
            current_offset += 5
        }

        return (value, current_offset)
    }

    /// Checks if the specified bytes can be read from the current chunk.
    /// - Parameters:
    ///   - offset: Position to start reading from.
    ///   - length: Number of bytes to read.
    /// - Returns: True if bytes can be read from current chunk, false otherwise.
    func can_read_from_current_chunk(offset: Int, length: Int) -> Bool {
        return offset - composite_buffer.current_chunk_offset + length <=
               composite_buffer.chunks[composite_buffer.current_chunk_index].count
    }

    /// Gets a pointer/view into the current chunk's data, creating it if necessary.
    /// - Returns: UnsafeRawPointer for the current chunk.
    func get_current_data_view() -> UnsafeRawBufferPointer {
        if composite_buffer.current_data_view == nil {
            composite_buffer.current_data_view = composite_buffer.chunks[composite_buffer.current_chunk_index]
        }
        return composite_buffer.current_data_view!.withUnsafeBytes { $0 }
    }
}
