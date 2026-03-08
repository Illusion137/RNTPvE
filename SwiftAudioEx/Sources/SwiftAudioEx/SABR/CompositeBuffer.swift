import Foundation

// MARK: - CompositeBuffer

/// A memory-efficient buffer that manages discontinuous chunks as a single logical stream.
class CompositeBuffer {
    var chunks: [Data]
    var current_chunk_offset: Int
    var current_chunk_index: Int
    var current_data_view: Data?
    var total_length: Int

    init(chunks: [Data] = []) {
        self.chunks = []
        self.current_chunk_offset = 0
        self.current_chunk_index = 0
        self.current_data_view = nil
        self.total_length = 0
        chunks.forEach { append(chunk: $0) }
    }

    func append(chunk: Data) {
        if can_merge_with_last_chunk(chunk: chunk) {
            let last_index = chunks.count - 1
            chunks[last_index].append(chunk)
            reset_focus()
        } else {
            chunks.append(chunk)
        }
        total_length += chunk.count
    }

    func append(composite: CompositeBuffer) {
        composite.chunks.forEach { append(chunk: $0) }
    }

    struct SplitResult {
        let extracted_buffer: CompositeBuffer
        let remaining_buffer: CompositeBuffer
    }

    func split(position: Int) -> SplitResult {
        let extracted_buffer = CompositeBuffer()
        let remaining_buffer = CompositeBuffer()
        var remaining_position = position

        for chunk in chunks {
            if remaining_position >= chunk.count {
                extracted_buffer.append(chunk: chunk)
                remaining_position -= chunk.count
            } else if remaining_position > 0 {
                extracted_buffer.append(chunk: chunk.subdata(in: 0..<remaining_position))
                remaining_buffer.append(chunk: chunk.subdata(in: remaining_position..<chunk.count))
                remaining_position = 0
            } else {
                remaining_buffer.append(chunk: chunk)
            }
        }

        return SplitResult(extracted_buffer: extracted_buffer, remaining_buffer: remaining_buffer)
    }

    func get_length() -> Int {
        return total_length
    }

    func can_read_bytes(position: Int, length: Int) -> Bool {
        return position + length <= total_length
    }

    func get_uint8(position: Int) -> UInt8 {
        focus(position: position)
        return chunks[current_chunk_index][position - current_chunk_offset]
    }

    func focus(position: Int) {
        if !is_focused(position: position) {
            if position < current_chunk_offset {
                reset_focus()
            }

            while current_chunk_index < chunks.count - 1 &&
                  current_chunk_offset + chunks[current_chunk_index].count <= position {
                current_chunk_offset += chunks[current_chunk_index].count
                current_chunk_index += 1
            }

            current_data_view = nil
        }
    }

    func is_focused(position: Int) -> Bool {
        return position >= current_chunk_offset &&
               position < current_chunk_offset + chunks[current_chunk_index].count
    }

    private func reset_focus() {
        current_data_view = nil
        current_chunk_index = 0
        current_chunk_offset = 0
    }

    private func can_merge_with_last_chunk(chunk: Data) -> Bool {
        guard chunks.count > 0 else { return false }
        // In Swift, Data copies memory so contiguous merging like JS buffers isn't directly applicable.
        // We conservatively never merge.
        return false
    }
}