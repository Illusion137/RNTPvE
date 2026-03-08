import Foundation

// MARK: - CacheManager

/// Simple in-memory segment cache with max size and age limits.
class CacheManager {
    private struct Entry {
        let data: Data
        var timestamp: Date
        let size: Int
    }

    private var init_cache: [String: Entry] = [:]
    private var segment_cache: [String: Entry] = [:]
    private var current_size_bytes: Int = 0
    private let max_size_bytes: Int
    private let max_age_seconds: TimeInterval
    private let logger = Logger.get_instance()
    private var gc_timer: Timer?

    init(max_size_mb: Int? = nil, max_age_seconds: Int? = nil) {
        self.max_size_bytes = (max_size_mb ?? 50) * 1024 * 1024
        self.max_age_seconds = TimeInterval(max_age_seconds ?? 300)
        start_gc()
    }

    func set_init_segment(key: String, data: Data) {
        let entry = Entry(data: data, timestamp: Date(), size: data.count)
        if init_cache[key] == nil {
            current_size_bytes += entry.size
            enforce_limit()
        }
        init_cache[key] = entry
    }

    func get_init_segment(key: String) -> Data? {
        guard let entry = init_cache[key] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > max_age_seconds {
            init_cache.removeValue(forKey: key)
            current_size_bytes -= entry.size
            return nil
        }
        logger.debug(tag: "CacheManager", message: "Cache hit for init segment: \(key)")
        return entry.data
    }

    func dispose() {
        init_cache.removeAll()
        segment_cache.removeAll()
        current_size_bytes = 0
        gc_timer?.invalidate()
        gc_timer = nil
    }

    private func enforce_limit() {
        guard current_size_bytes > max_size_bytes else { return }
        // Remove expired entries first
        let now = Date()
        for (key, entry) in segment_cache where now.timeIntervalSince(entry.timestamp) > max_age_seconds {
            segment_cache.removeValue(forKey: key)
            current_size_bytes -= entry.size
        }
        for (key, entry) in init_cache where now.timeIntervalSince(entry.timestamp) > max_age_seconds {
            init_cache.removeValue(forKey: key)
            current_size_bytes -= entry.size
        }
        // If still over, remove oldest
        if current_size_bytes > max_size_bytes {
            var all = (segment_cache.map { ($0.key, $0.value, false) } +
                       init_cache.map { ($0.key, $0.value, true) })
                .sorted { $0.1.timestamp < $1.1.timestamp }
            while current_size_bytes > max_size_bytes, !all.isEmpty {
                let (key, entry, isInit) = all.removeFirst()
                if isInit { init_cache.removeValue(forKey: key) }
                else { segment_cache.removeValue(forKey: key) }
                current_size_bytes -= entry.size
            }
        }
    }

    private func start_gc() {
        DispatchQueue.main.async { [weak self] in
            self?.gc_timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.enforce_limit()
            }
        }
    }
}
