import Foundation

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
    
    /// Emit a log message if verbose mode is enabled.
    static func debug(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        print(message())
    }
}
