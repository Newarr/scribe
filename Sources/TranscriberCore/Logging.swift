import os

public enum Log {
    static let subsystem = "com.szymonsypniewicz.transcriber"

    public static let lifecycle    = Logger(subsystem: subsystem, category: "lifecycle")
    public static let capture      = Logger(subsystem: subsystem, category: "capture")
    public static let engine       = Logger(subsystem: subsystem, category: "engine")
    public static let calendar     = Logger(subsystem: subsystem, category: "calendar")
    public static let permissions  = Logger(subsystem: subsystem, category: "permissions")
    public static let storage      = Logger(subsystem: subsystem, category: "storage")
    public static let diagnostics  = Logger(subsystem: subsystem, category: "diagnostics")

    static let categories: [String] = [
        "lifecycle", "capture", "engine", "calendar",
        "permissions", "storage", "diagnostics"
    ]
}
