import XCTest
@testable import ReaderCore
final class TaskListEditTests: XCTestCase {
    func testTogglePreservesUnicodeLineEndingsAndOtherTasks() throws {
        let source = "😀 Title\r\n- [ ] Same\r\n- [X] Same\r\n"
        let offset = (source as NSString).range(of: "[ ]").location + 1
        let checked = try XCTUnwrap(TaskListEdit.setChecked(true, atUTF16: offset, in: source))
        XCTAssertEqual(checked, "😀 Title\r\n- [x] Same\r\n- [X] Same\r\n")
        XCTAssertEqual(TaskListEdit.setChecked(false, atUTF16: offset, in: checked), source)
        XCTAssertNil(TaskListEdit.setChecked(true, atUTF16: -1, in: source))
        XCTAssertNil(TaskListEdit.setChecked(true, atUTF16: 1, in: source))
        XCTAssertNil(TaskListEdit.setChecked(true, atUTF16: source.utf16.count, in: source))
    }
}
