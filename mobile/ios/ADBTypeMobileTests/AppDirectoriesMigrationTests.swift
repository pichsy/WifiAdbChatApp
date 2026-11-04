import XCTest
@testable import ADBTypeMobile

final class AppDirectoriesMigrationTests: XCTestCase {
    func testDefaultReceiveDirectoryIsDocumentsDownloads() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        XCTAssertEqual(AppDirectories.receivedDirectory.deletingLastPathComponent().lastPathComponent, "Documents")
        XCTAssertEqual(AppDirectories.receivedDirectory.lastPathComponent, "Downloads")
        XCTAssertEqual(AppDirectories.legacyReceivedDirectory.lastPathComponent, "Received")
        XCTAssertEqual(AppDirectories.receivedDirectory.deletingLastPathComponent().path,
                       documents?.path)
    }

    func testMigrationMovesFilesAndHandlesNameCollision() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try FileManager.default.createDirectory(at: env.legacy, withIntermediateDirectories: true)
        let legacyData = Data("legacy 📦".utf8)
        let existingData = Data("existing".utf8)
        try legacyData.write(to: env.legacy.appendingPathComponent("报告.pdf"))
        try existingData.write(to: env.downloads.appendingPathComponent("报告.pdf"))

        let mapping = AppDirectories.migrateLegacyReceivedFiles(legacyDirectory: env.legacy,
                                                                destination: env.downloads)

        XCTAssertEqual(mapping, ["报告.pdf": "报告 (2).pdf"])
        XCTAssertEqual(try Data(contentsOf: env.downloads.appendingPathComponent("报告 (2).pdf")), legacyData)
        XCTAssertEqual(try Data(contentsOf: env.downloads.appendingPathComponent("报告.pdf")), existingData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.legacy.appendingPathComponent("报告.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.legacy.path), "空旧目录应被删除")
    }

    func testMigrationDoesNothingWhenLegacyDirectoryMissing() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let mapping = AppDirectories.migrateLegacyReceivedFiles(legacyDirectory: env.legacy,
                                                                destination: env.downloads)
        XCTAssertTrue(mapping.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.legacy.path))
    }

    func testMigrationKeepsNonEmptyLegacyDirectory() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try FileManager.default.createDirectory(at: env.legacy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: env.legacy.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: env.legacy.appendingPathComponent("子文件夹"),
                                                withIntermediateDirectories: true)

        _ = AppDirectories.migrateLegacyReceivedFiles(legacyDirectory: env.legacy,
                                                      destination: env.downloads)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.legacy.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.legacy.appendingPathComponent("子文件夹").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.legacy.path))
    }

    private struct Environment {
        let root: URL
        let legacy: URL
        let downloads: URL
    }

    private func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTypeMobileMigration-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("Documents/Received", isDirectory: true)
        let downloads = root.appendingPathComponent("Documents/Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        return Environment(root: root, legacy: legacy, downloads: downloads)
    }
}
