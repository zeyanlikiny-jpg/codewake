import XCTest

final class AllDisplaysSleepPreparationTests: XCTestCase {
    private let externalDisplays: [AllDisplaysSleepTopology.Display] = [
        .init(id: 10, isBuiltIn: false), .init(id: 20, isBuiltIn: false)
    ]

    func testDeferredRecoveryRequiresKnownClosedLidAndOnlyExternalDisplays() {
        XCTAssertTrue(AllDisplaysSleepTopology.known(
            lidClosed: true, displays: externalDisplays
        ).permitsDeferredBuiltInRecovery)
        let rejected: [AllDisplaysSleepTopology] = [
            .unknown,
            .known(lidClosed: nil, displays: externalDisplays),
            .known(lidClosed: false, displays: externalDisplays),
            .known(lidClosed: true, displays: []),
            .known(lidClosed: true, displays: [.init(id: 1, isBuiltIn: true)]),
            .known(lidClosed: true, displays: externalDisplays + [.init(id: 1, isBuiltIn: true)]),
            .known(lidClosed: true, displays: externalDisplays + [externalDisplays[0]])
        ]
        for topology in rejected {
            XCTAssertFalse(topology.permitsDeferredBuiltInRecovery, "\(topology)")
        }
    }

    func testStableReadSortsCompleteDisplayIdentity() {
        var reads = 0
        let topology = AllDisplaysSleepTopology.resolve(using: .init(
            onlineDisplays: {
                reads += 1
                return reads == 1 ? self.externalDisplays : self.externalDisplays.reversed()
            },
            lidClosed: { true }
        ))
        XCTAssertEqual(topology, .known(lidClosed: true, displays: externalDisplays))
        XCTAssertTrue(topology.permitsDeferredBuiltInRecovery)
        XCTAssertEqual(reads, 2)
    }

    func testDesktopWithUnknownLidCanSleepButCannotDeferRecovery() {
        let topology = AllDisplaysSleepTopology.resolve(using: .init(
            onlineDisplays: { self.externalDisplays }, lidClosed: { nil }
        ))
        XCTAssertTrue(topology.isKnown)
        XCTAssertFalse(topology.permitsDeferredBuiltInRecovery)
    }

    func testEmptyDuplicateZeroAndCapacityDisplayListsAreUnknown() {
        let lists: [[AllDisplaysSleepTopology.Display]?] = [
            nil, [], [.init(id: 0, isBuiltIn: false)],
            externalDisplays + [externalDisplays[0]],
            (1...64).map { .init(id: UInt32($0), isBuiltIn: false) }
        ]
        for list in lists {
            let topology = AllDisplaysSleepTopology.resolve(using: .init(
                onlineDisplays: { list }, lidClosed: { true }
            ))
            XCTAssertEqual(topology, .unknown)
            XCTAssertFalse(topology.permitsDeferredBuiltInRecovery)
        }
    }

    func testLidChangeAcrossDisplayReadsIsUnknown() {
        var lidReads = 0
        let topology = AllDisplaysSleepTopology.resolve(using: .init(
            onlineDisplays: { self.externalDisplays },
            lidClosed: {
                lidReads += 1
                return lidReads == 1
            }
        ))
        XCTAssertEqual(topology, .unknown)
    }

    func testLidBecomingUnavailableAcrossDisplayReadsIsUnknown() {
        var lidReads = 0
        let topology = AllDisplaysSleepTopology.resolve(using: .init(
            onlineDisplays: { self.externalDisplays },
            lidClosed: {
                lidReads += 1
                return lidReads == 1 ? true : nil
            }
        ))
        XCTAssertEqual(topology, .unknown)
    }

    func testDisplayReplacementOrBuiltInClassificationChangeIsUnknown() {
        let changedSets: [[AllDisplaysSleepTopology.Display]] = [
            [.init(id: 10, isBuiltIn: false), .init(id: 99, isBuiltIn: false)],
            [.init(id: 10, isBuiltIn: true), .init(id: 20, isBuiltIn: false)]
        ]
        for changed in changedSets {
            var reads = 0
            let topology = AllDisplaysSleepTopology.resolve(using: .init(
                onlineDisplays: {
                    reads += 1
                    return reads == 1 ? self.externalDisplays : changed
                },
                lidClosed: { true }
            ))
            XCTAssertEqual(topology, .unknown)
        }
    }

    func testSecondDisplayReadFailureCannotReuseTheFirstList() {
        var reads = 0
        let topology = AllDisplaysSleepTopology.resolve(using: .init(
            onlineDisplays: {
                reads += 1
                return reads == 1 ? self.externalDisplays : nil
            },
            lidClosed: { true }
        ))
        XCTAssertEqual(topology, .unknown)
    }
}
