import Foundation
import os

/// Centralized logging utility so we can silence verbose output in release/distribution builds.
/// Set `Logging.isVerbose = false` before packaging a release to greatly reduce console noise.
enum Logging {
    /// Controls whether verbose diagnostic logs are emitted.
    /// Default is true in DEBUG builds, false otherwise.
#if DEBUG
    static var isVerbose: Bool = true
#else
    static var isVerbose: Bool = false
#endif

    private static let logger = Logger(subsystem: BuildInfo.bundleIdentifier, category: "app")

    /// Emit a log message if verbose mode is enabled.
    ///
    /// These stay on stdout only: verbose messages may reference clipboard content, so
    /// they must never reach the unified log where they would outlive the process.
    static func debug(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        print(message())
    }

    /// Emit an informational log message. These are always recorded so they remain visible
    /// in release builds, which is the only way to diagnose an installed copy in the field:
    ///
    ///     log show --predicate 'subsystem == "com.macclipboard.app"' --last 1h
    ///
    /// Emitted at `notice` level on purpose: os_log keeps `info` level entries in a memory
    /// buffer that `log show` cannot read back afterwards, whereas `notice` is persisted.
    ///
    /// Only pass messages that carry no clipboard content: unified log entries persist.
    static func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.notice("\(text, privacy: .public)")
        if isVerbose { print(text) }
    }
}
