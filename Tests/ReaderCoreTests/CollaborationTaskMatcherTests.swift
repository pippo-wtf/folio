import XCTest
@testable import ReaderCore

final class CollaborationTaskMatcherTests: XCTestCase {
    private let rawRevision = String(repeating: "a", count: 64)

    func testAnchorUsesSourceUTF16AndKeepsRawRevisionSeparate() throws {
        let source = "😀 Heading\r\n- [ ] Ship\r\n"
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: 15, in: source, rawSourceRevision: rawRevision))
        XCTAssertEqual(anchor.sourceOffsetUTF16, 15)
        XCTAssertEqual(anchor.line, "- [ ] Ship")
        XCTAssertEqual(anchor.prefix, "😀 Heading\r\n")
        XCTAssertEqual(anchor.suffix, "\r\n")
        XCTAssertEqual(anchor.rawSourceRevision, rawRevision)
        XCTAssertEqual(anchor.decodedSourceRevision, HighlightStore.revision(source))
        XCTAssertNotEqual(anchor.rawSourceRevision, anchor.decodedSourceRevision)
        XCTAssertEqual(SharedTaskMatcher.locate(anchor, in: source), 15)
    }

    func testExactRevisionDisambiguatesDuplicateLinesByValidatedOffset() throws {
        let source = "- [ ] Same\n- [ ] Same\n"
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: 14, in: source, rawSourceRevision: rawRevision))
        XCTAssertEqual(SharedTaskMatcher.locate(anchor, in: source), 14)
    }

    func testChangedCheckboxStateStillLocatesSameTask() throws {
        let source = "Before\n- [ ] Ship\nAfter\n"
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: 10, in: source, rawSourceRevision: rawRevision))
        XCTAssertEqual(SharedTaskMatcher.locate(anchor, in: "Before\n- [X] Ship\nAfter\n"), 10)
    }

    func testInsertionBeforeStableContextReturnsShiftedOffset() throws {
        let source = String(repeating: "a", count: 80) + "\n- [ ] Ship\nAfter\n"
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: 84, in: source, rawSourceRevision: rawRevision))
        XCTAssertEqual(SharedTaskMatcher.locate(anchor, in: "😀 Intro\n" + source), 93)
    }

    func testDeletedOrRenamedTaskHasNoMatch() throws {
        let source = "Before\n- [ ] Ship\nAfter\n"
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: 10, in: source, rawSourceRevision: rawRevision))
        XCTAssertNil(SharedTaskMatcher.locate(anchor, in: "Before\nAfter\n"))
        XCTAssertNil(SharedTaskMatcher.locate(anchor, in: "Before\n- [ ] Changed\nAfter\n"))
        XCTAssertNil(SharedTaskMatcher.locate(anchor, in: "Different\n- [ ] Ship\nAfter\n"))
    }

    func testChangedRevisionNeverChoosesBetweenIdenticalContexts() throws {
        let block = String(repeating: "a", count: 80) + "\n- [ ] Same\n" + String(repeating: "b", count: 80) + "\n"
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: 84, in: block, rawSourceRevision: rawRevision))
        XCTAssertNil(SharedTaskMatcher.locate(anchor, in: block + block))
    }

    func testCreationRejectsIndistinguishableRepeatedTaskContexts() {
        let block = String(repeating: "a", count: 80) + "\n- [ ] Same\n" + String(repeating: "b", count: 80) + "\n"
        XCTAssertNil(SharedTaskMatcher.anchor(atUTF16: 84, in: block + block, rawSourceRevision: rawRevision))
    }

    func testDeletedDuplicateDoesNotFallBackToRemainingLabel() throws {
        let source = "First\n- [ ] Same\nSecond\n- [ ] Same\nEnd\n"
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: 9, in: source, rawSourceRevision: rawRevision))
        XCTAssertNil(SharedTaskMatcher.locate(anchor, in: "First\nSecond\n- [ ] Same\nEnd\n"))
    }

    func testCreationRejectsInvalidOffsetsRevisionsAndNonTaskCheckboxes() {
        let source = "- [ ] Ship\nText [ ] incidental\n"
        for offset in [-1, 0, 2, 4, 16, Int.max] {
            XCTAssertNil(SharedTaskMatcher.anchor(atUTF16: offset, in: source, rawSourceRevision: rawRevision))
        }
        XCTAssertNil(SharedTaskMatcher.anchor(atUTF16: 3, in: source, rawSourceRevision: "invalid"))
        XCTAssertNil(SharedTaskMatcher.anchor(atUTF16: 3, in: "- [ ] " + String(repeating: "a", count: 20_001), rawSourceRevision: rawRevision))
    }

    func testCheckboxLikeLabelTextChangeRequiresReattachment() throws {
        let source = "Before\n- [ ] Ship [ ] flag\nAfter\n"
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: 10, in: source, rawSourceRevision: rawRevision))
        XCTAssertNil(SharedTaskMatcher.locate(anchor, in: "Before\n- [ ] Ship [x] flag\nAfter\n"))
    }

    func testNeighborCheckboxChangesDoNotInvalidateTaskContext() throws {
        let source = "- [ ] Before\n- [ ] Ship\n- [ ] After\n"
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: 16, in: source, rawSourceRevision: rawRevision))
        XCTAssertEqual(SharedTaskMatcher.locate(anchor, in: "- [x] Before\n- [X] Ship\n- [x] After\n"), 16)
    }

    func testContextLimitDoesNotSplitUTF16SurrogatePair() throws {
        let source = "😀" + String(repeating: "a", count: 62) + "\n- [ ] Ship\n" + String(repeating: "b", count: 62) + "😀"
        let anchor = try XCTUnwrap(SharedTaskMatcher.anchor(atUTF16: 68, in: source, rawSourceRevision: rawRevision))
        XCTAssertEqual(anchor.prefix, String(repeating: "a", count: 62) + "\n")
        XCTAssertEqual(anchor.suffix, "\n" + String(repeating: "b", count: 62))
        XCTAssertEqual(SharedTaskMatcher.locate(anchor, in: "Intro\n" + source), 74)
    }

    func testMalformedAnchorCannotExploitExactRevisionOffset() throws {
        let source = "Before\n- [ ] Ship\nAfter\n"
        let anchor = SharedTaskAnchor(sourceOffsetUTF16: 10, line: "- [ ] Other", prefix: "Before\n", suffix: "\nAfter\n", rawSourceRevision: rawRevision, decodedSourceRevision: HighlightStore.revision(source))
        XCTAssertNil(SharedTaskMatcher.locate(anchor, in: source))
    }
}
