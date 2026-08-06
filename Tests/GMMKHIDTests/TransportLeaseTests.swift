import XCTest
@testable import GMMKHID

/// The hand-off that keeps two owners off one transport.
///
/// ``GMMKKeyboard`` is one-thread-at-a-time by design, so this lease is what
/// stands between the menu and the visualizer's own thread. The interesting
/// cases are all the ones where a naive flag would go wrong: a late release, a
/// double start, and asking permission when nobody is holding it.
final class TransportLeaseTests: XCTestCase {

    func testStartsFree() {
        let lease = TransportLease()
        XCTAssertFalse(lease.isHeld)
        XCTAssertNil(lease.holder)
    }

    /// A free lease permits everyone. This is what keeps the ordinary case —
    /// no visualizer running — from needing an acquire around every menu action.
    func testAFreeLeaseIsAvailableToEveryone() {
        let lease = TransportLease()
        XCTAssertTrue(lease.isAvailable(to: .menu))
        XCTAssertTrue(lease.isAvailable(to: .visualizer))
    }

    func testAcquiringExcludesTheOtherOwner() {
        let lease = TransportLease()
        XCTAssertTrue(lease.acquire(.visualizer))
        XCTAssertEqual(lease.holder, .visualizer)
        XCTAssertTrue(lease.isHeld)

        XCTAssertTrue(lease.isAvailable(to: .visualizer))
        XCTAssertFalse(lease.isAvailable(to: .menu))
        XCTAssertFalse(lease.acquire(.menu))
        // The failed acquire did not steal it.
        XCTAssertEqual(lease.holder, .visualizer)
    }

    /// Starting the visualizer twice is a no-op, not a failure — the UI toggle
    /// can be clicked twice quickly and neither click should error.
    func testReacquiringYourOwnLeaseSucceeds() {
        let lease = TransportLease()
        XCTAssertTrue(lease.acquire(.visualizer))
        XCTAssertTrue(lease.acquire(.visualizer))
        XCTAssertEqual(lease.holder, .visualizer)
    }

    func testReleasingFreesIt() {
        let lease = TransportLease()
        lease.acquire(.visualizer)
        XCTAssertTrue(lease.release(.visualizer))
        XCTAssertNil(lease.holder)
        XCTAssertTrue(lease.isAvailable(to: .menu))
    }

    /// **The case a plain boolean gets wrong.** A teardown that arrives after
    /// someone else has taken the lease must not free it: the visualizer
    /// stopping late would otherwise unlock a transport the menu is now using.
    func testALateReleaseCannotFreeAnotherOwnersLease() {
        let lease = TransportLease()
        lease.acquire(.visualizer)
        lease.release(.visualizer)
        lease.acquire(.menu)

        XCTAssertFalse(lease.release(.visualizer))
        XCTAssertEqual(lease.holder, .menu, "the menu's lease was stolen by a late release")
    }

    func testReleasingAFreeLeaseIsHarmless() {
        let lease = TransportLease()
        XCTAssertFalse(lease.release(.menu))
        XCTAssertNil(lease.holder)
    }

    /// The whole point: while one owner holds it, the other's send path is
    /// closed and reopens the moment it is given back.
    func testHandOffSequence() {
        let lease = TransportLease()
        XCTAssertTrue(lease.isAvailable(to: .menu))

        lease.acquire(.visualizer)
        XCTAssertFalse(lease.isAvailable(to: .menu))

        lease.release(.visualizer)
        XCTAssertTrue(lease.isAvailable(to: .menu))
    }

    /// Contended from several threads, exactly one acquirer wins and the count
    /// of successes is one — the lock is doing its job.
    func testOnlyOneOwnerWinsUnderContention() {
        let lease = TransportLease()
        let successes = NSMutableArray()
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 64) { iteration in
            let owner: TransportLease.Owner = iteration.isMultiple(of: 2) ? .menu : .visualizer
            if lease.acquire(owner) {
                lock.lock()
                successes.add(owner.rawValue)
                lock.unlock()
            }
        }

        // Every success is the same owner — whoever got there first — because
        // re-acquiring your own lease also succeeds.
        let distinct = Set(successes.compactMap { $0 as? String })
        XCTAssertEqual(distinct.count, 1, "two owners both believed they held the lease")
        XCTAssertEqual(lease.holder?.rawValue, distinct.first)
    }
}
