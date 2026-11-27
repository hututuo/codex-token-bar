import XCTest
@testable import AgentSpeedCore

final class DeduperAllocationTests: XCTestCase {
    func testEmptyExactDedupersDoNotReserveForReadOnlyQueries() {
        for deduper in [Deduper(), Deduper(capacity: 1), Deduper(capacity: 3),
                        Deduper(capacity: 4096), Deduper(capacity: 0), Deduper(capacity: -7)] {
            XCTAssertEqual(deduper.ownerCapacity, 0)
            XCTAssertEqual(deduper.count, 0)
            XCTAssertFalse(deduper.contains("missing"))
            XCTAssertFalse(deduper.isOwnedByOtherFile("missing", for: 1))
            XCTAssertEqual(deduper.ownerCapacity, 0)
        }
        XCTAssertEqual(Deduper().capacity, 65_536)
        XCTAssertEqual(Deduper(capacity: 0).capacity, 1)
        XCTAssertEqual(Deduper(capacity: -7).capacity, 1)
    }

    func testFirstExactClaimMatchesOriginalReservation() {
        for capacity in [1, 3, 4096, Deduper.defaultCapacity] {
            var deduper = capacity == Deduper.defaultCapacity ? Deduper() : Deduper(capacity: capacity)
            var expected: [String: FileID] = [:]
            expected.reserveCapacity(min(capacity, 4096))
            expected["first"] = 7

            XCTAssertEqual(deduper.ownerCapacity, 0)
            XCTAssertEqual(deduper.claim("first", for: 7), .new)
            XCTAssertEqual(deduper.ownerCapacity, expected.capacity,
                    "Use the original reservation on first insertion, not on initialization")
            let allocated = deduper.ownerCapacity
            XCTAssertGreaterThan(allocated, 0)
            XCTAssertEqual(deduper.claim("first", for: 7), .sameFile)
            XCTAssertEqual(deduper.claim("first", for: 8), .otherFile)
            XCTAssertTrue(deduper.contains("first"))
            XCTAssertFalse(deduper.isOwnedByOtherFile("first", for: 7))
            XCTAssertTrue(deduper.isOwnedByOtherFile("first", for: 8))
            XCTAssertEqual(deduper.count, 1)
            XCTAssertEqual(deduper.ownerCapacity, allocated)
        }
    }

    func testDefaultFIFOEvictsAt65536WithoutRefreshingRepeatedKeys() {
        var deduper = Deduper()
        var allNew = true
        for index in 0..<65_536 {
            let claim = deduper.claim("key-\(index)", for: 1)
            allNew = allNew && claim == .new
        }
        XCTAssertTrue(allNew)
        XCTAssertEqual(deduper.count, 65_536)
        XCTAssertEqual(deduper.claim("key-0", for: 1), .sameFile)
        XCTAssertEqual(deduper.claim("key-0", for: 2), .otherFile)

        XCTAssertEqual(deduper.claim("overflow", for: 2), .new)
        XCTAssertFalse(deduper.contains("key-0"), "Repeated claims must not refresh FIFO order")
        XCTAssertTrue(deduper.contains("key-1"))
        XCTAssertTrue(deduper.contains("key-65535"))
        XCTAssertEqual(deduper.count, 65_536)
        XCTAssertEqual(deduper.claim("key-0", for: 2), .new)
        XCTAssertFalse(deduper.contains("key-1"))
        XCTAssertEqual(deduper.claim("key-0", for: 2), .sameFile)
        XCTAssertEqual(deduper.claim("key-0", for: 1), .otherFile)
        XCTAssertEqual(deduper.count, 65_536)
    }

    func testCapacityOneAndClampedCapacitiesPreserveFIFOOwnership() {
        for capacity in [-7, 0, 1] {
            var deduper = Deduper(capacity: capacity)
            XCTAssertEqual(deduper.ownerCapacity, 0)
            XCTAssertEqual(deduper.claim("a", for: 1), .new)
            XCTAssertEqual(deduper.claim("a", for: 2), .otherFile)
            XCTAssertEqual(deduper.claim("b", for: 2), .new)
            XCTAssertFalse(deduper.contains("a"))
            XCTAssertEqual(deduper.claim("b", for: 2), .sameFile)
            XCTAssertEqual(deduper.claim("a", for: 3), .new)
            XCTAssertFalse(deduper.contains("b"))
            XCTAssertEqual(deduper.claim("a", for: 1), .otherFile)
            XCTAssertEqual(deduper.claim("a", for: 3), .sameFile)
            XCTAssertEqual(deduper.count, 1)
        }
    }

    func testCopiesBeforeFirstClaimAllocateAndOwnKeysIndependently() {
        var original = Deduper(capacity: 2)
        var copy = original
        XCTAssertEqual(copy.claim("shared", for: 2), .new)
        XCTAssertGreaterThan(copy.ownerCapacity, 0)
        XCTAssertEqual(original.ownerCapacity, 0)
        XCTAssertFalse(original.contains("shared"))
        XCTAssertEqual(original.claim("shared", for: 1), .new)
        XCTAssertEqual(original.claim("shared", for: 1), .sameFile)
        XCTAssertEqual(copy.claim("shared", for: 1), .otherFile)
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(copy.count, 1)
    }

    func testCopiesAfterAllocationKeepOwnersAndFIFOIndependent() {
        var original = Deduper(capacity: 2)
        XCTAssertEqual(original.claim("a", for: 1), .new)
        XCTAssertEqual(original.claim("b", for: 1), .new)
        var copy = original
        XCTAssertEqual(copy.ownerCapacity, original.ownerCapacity)

        XCTAssertEqual(original.claim("c", for: 2), .new)
        XCTAssertFalse(original.contains("a"))
        XCTAssertTrue(copy.contains("a"))
        XCTAssertFalse(copy.contains("c"))
        XCTAssertEqual(copy.claim("d", for: 3), .new)
        XCTAssertFalse(copy.contains("a"))
        XCTAssertFalse(original.contains("d"))
        XCTAssertEqual(copy.claim("b", for: 1), .sameFile)
        XCTAssertEqual(original.claim("a", for: 4), .new)
        XCTAssertFalse(original.contains("b"))
        XCTAssertTrue(copy.contains("b"), "Advancing one FIFO must not mutate its copied ring")
        XCTAssertEqual(original.count, 2)
        XCTAssertEqual(copy.count, 2)
    }

    func testHashedOperationsNeverReserveExactOwners() {
        var deduper = Deduper.hashed()
        XCTAssertEqual(deduper.ownerCapacity, 0)
        XCTAssertEqual(deduper.count, 0)
        XCTAssertFalse(deduper.contains("missing"))
        XCTAssertFalse(deduper.isOwnedByOtherFile("missing", for: 7))
        XCTAssertEqual(deduper.ownerCapacity, 0)

        let settled = KeyHash.fnv1a("settled")
        deduper.insertSettled([settled, settled])
        XCTAssertEqual(deduper.ownerCapacity, 0)
        XCTAssertEqual(deduper.count, 1)
        XCTAssertTrue(deduper.contains("settled"))
        XCTAssertTrue(deduper.isOwnedByOtherFile("settled", for: 7))
        XCTAssertEqual(deduper.claim("settled", for: 7), .otherFile)
        XCTAssertEqual(deduper.ownerCapacity, 0)
        XCTAssertEqual(deduper.claim("a", for: 7), .new)
        XCTAssertEqual(deduper.ownerCapacity, 0)
        XCTAssertEqual(deduper.claim("a", for: 7), .sameFile)
        XCTAssertFalse(deduper.isOwnedByOtherFile("a", for: 7))
        XCTAssertTrue(deduper.isOwnedByOtherFile("a", for: 8))
        XCTAssertEqual(deduper.ownerCapacity, 0)
        XCTAssertEqual(deduper.claim("b", for: 7), .new)
        XCTAssertEqual(deduper.ownerCapacity, 0)
        XCTAssertEqual(deduper.finishFile(), [KeyHash.fnv1a("a"), KeyHash.fnv1a("b")])
        XCTAssertEqual(deduper.ownerCapacity, 0)
        XCTAssertEqual(deduper.count, 3)
        XCTAssertEqual(deduper.claim("a", for: 7), .otherFile)
        XCTAssertEqual(deduper.ownerCapacity, 0)

        XCTAssertEqual(deduper.claim("c", for: 8), .new)
        XCTAssertEqual(deduper.ownerCapacity, 0)
        XCTAssertEqual(deduper.claim("d", for: 9), .new)
        XCTAssertEqual(deduper.ownerCapacity, 0)
        XCTAssertTrue(deduper.isOwnedByOtherFile("c", for: 8),
                "Changing files settles the previous file's hashes")
        XCTAssertEqual(deduper.finishFile(), [KeyHash.fnv1a("d")])
        XCTAssertEqual(deduper.ownerCapacity, 0)
        XCTAssertTrue(deduper.finishFile().isEmpty)
        XCTAssertEqual(deduper.ownerCapacity, 0)
        XCTAssertEqual(deduper.count, 5)
    }
}
