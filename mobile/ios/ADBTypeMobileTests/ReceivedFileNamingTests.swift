import XCTest
@testable import ADBTypeMobile

final class ReceivedFileNamingTests: XCTestCase {
    func testSanitizesPathTraversal() {
        XCTAssertEqual(ReceivedFileNaming.sanitizedFileName("photo.png"), "photo.png")
        XCTAssertEqual(ReceivedFileNaming.sanitizedFileName("/tmp/evil.txt"), "evil.txt")
        XCTAssertEqual(ReceivedFileNaming.sanitizedFileName("..\\..\\secret.txt"), "secret.txt")
        XCTAssertEqual(ReceivedFileNaming.sanitizedFileName("a/b/c.txt"), "c.txt")
        XCTAssertEqual(ReceivedFileNaming.sanitizedFileName("  report.pdf  "), "report.pdf")
    }

    func testRejectsUnsafeNames() {
        XCTAssertNil(ReceivedFileNaming.sanitizedFileName(""))
        XCTAssertNil(ReceivedFileNaming.sanitizedFileName("   "))
        XCTAssertNil(ReceivedFileNaming.sanitizedFileName("."))
        XCTAssertNil(ReceivedFileNaming.sanitizedFileName(".."))
        XCTAssertNil(ReceivedFileNaming.sanitizedFileName("/"))
        XCTAssertNil(ReceivedFileNaming.sanitizedFileName("folder/.."))
    }

    func testUniqueDestinationAddsNumber() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = ReceivedFileNaming.uniqueDestination(in: directory, fileName: "报告.pdf")
        XCTAssertEqual(first.lastPathComponent, "报告.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: first.path, contents: Data("1".utf8)))

        let second = ReceivedFileNaming.uniqueDestination(in: directory, fileName: "报告.pdf")
        XCTAssertEqual(second.lastPathComponent, "报告 (2).pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: second.path, contents: Data("2".utf8)))

        let third = ReceivedFileNaming.uniqueDestination(in: directory, fileName: "报告.pdf")
        XCTAssertEqual(third.lastPathComponent, "报告 (3).pdf")
    }

    func testUniqueDestinationHandlesMissingExtensionAndMultipleDots() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let readme = ReceivedFileNaming.uniqueDestination(in: directory, fileName: "README")
        XCTAssertTrue(FileManager.default.createFile(atPath: readme.path, contents: Data()))
        XCTAssertEqual(ReceivedFileNaming.uniqueDestination(in: directory, fileName: "README").lastPathComponent,
                       "README (2)")

        let archive = ReceivedFileNaming.uniqueDestination(in: directory, fileName: "archive.tar.gz")
        XCTAssertTrue(FileManager.default.createFile(atPath: archive.path, contents: Data()))
        XCTAssertEqual(ReceivedFileNaming.uniqueDestination(in: directory, fileName: "archive.tar.gz").lastPathComponent,
                       "archive.tar (2).gz")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTypeMobileNaming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
