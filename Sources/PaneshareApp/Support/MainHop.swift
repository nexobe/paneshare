#if os(macOS)
import Foundation

/// Runs `body` on the main actor, in submission order. `Task { @MainActor }` doesn't promise FIFO,
/// and protocol messages must be handled in the order they arrived.
func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}
#endif
