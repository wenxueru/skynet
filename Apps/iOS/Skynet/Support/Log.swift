import Foundation
import os

/// Central logging wrapper. Categories mirror the app's layers so filtering
/// in Console is straightforward.
public enum Log {
    public static let pairing = Logger(subsystem: subsystem, category: "pairing")
    public static let relay = Logger(subsystem: subsystem, category: "relay")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let composer = Logger(subsystem: subsystem, category: "composer")
    public static let notifications = Logger(subsystem: subsystem, category: "notifications")
    public static let navigation = Logger(subsystem: subsystem, category: "navigation")
    public static let library = Logger(subsystem: subsystem, category: "library")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "app.skynet"
}
