import os

/// Unified logging, one category per subsystem area. Everything lands in the
/// system log (Console.app, `log show --predicate 'subsystem == "io.github.hasso5703.soyle"'`),
/// so a failure is never trapped inside the process. User-visible *errors* go
/// through `ErrorLog` as well, which keeps a small on-disk journal for the
/// "Report a Problem" flow.
public enum Log {
    public static let subsystem = "io.github.hasso5703.soyle"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let model = Logger(subsystem: subsystem, category: "model")
    public static let download = Logger(subsystem: subsystem, category: "download")
    public static let update = Logger(subsystem: subsystem, category: "update")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let paste = Logger(subsystem: subsystem, category: "paste")
    public static let tts = Logger(subsystem: subsystem, category: "tts")
}
