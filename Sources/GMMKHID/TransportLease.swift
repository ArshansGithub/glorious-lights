import Foundation

/// Exclusive use of one device's transport, handed between the parts of the app
/// that want to drive it.
///
/// ``GMMKKeyboard`` is one-thread-at-a-time by design: it schedules on a run
/// loop, keeps a single `latestReply` slot, and paces sends by pumping that run
/// loop. Two owners sending at once would interleave packets inside a
/// `START`/`END` transaction and consume each other's echoes. The audio
/// visualizer needs to drive the keyboard continuously from its own thread, so
/// rather than sharing an instance it takes the lease, and the menu's own
/// controller stops sending until it is given back.
///
/// This is a *cooperative* lock over intent, not a mutex over an object. It
/// does not make concurrent use safe — it makes concurrent use not happen.
/// Holders are named so a refusal can say who is holding it.
public final class TransportLease {

    /// Names used by this app, so a typo cannot silently create a second
    /// "owner" that never matches.
    public enum Owner: String, Sendable {
        /// The menu-bar controls.
        case menu
        /// The audio visualizer's own transport and thread.
        case visualizer
    }

    private let lock = NSLock()
    private var currentHolder: Owner?

    public init() {}

    /// Who holds it, or `nil` when it is free.
    public var holder: Owner? {
        lock.lock()
        defer { lock.unlock() }
        return currentHolder
    }

    public var isHeld: Bool { holder != nil }

    /// Takes the lease for `owner`.
    ///
    /// - Returns: `true` if `owner` now holds it. Re-acquiring a lease you
    ///   already hold succeeds — starting the visualizer twice is a no-op rather
    ///   than an error — but taking one another owner holds fails.
    @discardableResult
    public func acquire(_ owner: Owner) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let currentHolder, currentHolder != owner { return false }
        currentHolder = owner
        return true
    }

    /// Gives the lease back.
    ///
    /// - Returns: `true` if `owner` was holding it. Releasing a lease you do not
    ///   hold does nothing and says so, so a late teardown cannot free the lease
    ///   out from under whoever took it next.
    @discardableResult
    public func release(_ owner: Owner) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentHolder == owner else { return false }
        currentHolder = nil
        return true
    }

    /// Whether `owner` may send: either nobody holds the lease, or `owner` does.
    ///
    /// This is the check every send path makes. The default — free means allowed
    /// — keeps the ordinary case (no visualizer running) costing nothing and
    /// needing no acquire/release around every menu action.
    public func isAvailable(to owner: Owner) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentHolder == nil || currentHolder == owner
    }
}
