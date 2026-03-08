import Foundation

// MARK: - Logger

/// Singleton logger for SABR internals.
class Logger {
    private static var _instance: Logger?

    static func get_instance() -> Logger {
        if _instance == nil { _instance = Logger() }
        return _instance!
    }

    private init() {}

    func debug(tag: String, message: String) {
        #if DEBUG
        print("[DEBUG] [\(tag)] \(message)")
        #endif
    }

    func info(tag: String, message: String) {
        print("[INFO] [\(tag)] \(message)")
    }

    func warn(tag: String, message: String) {
        print("[WARN] [\(tag)] \(message)")
    }

    func error(tag: String, message: String) {
        print("[ERROR] [\(tag)] \(message)")
    }
}
