import XCTest
@testable import ADBTypeMobile

final class DeviceIdentityTests: XCTestCase {
    func testDeviceIDIsStableAndPersisted() throws {
        let suiteName = "ADBTypeMobileTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = DeviceIdentity.loadOrCreateDeviceID(defaults: defaults)
        let second = DeviceIdentity.loadOrCreateDeviceID(defaults: defaults)
        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(defaults.string(forKey: DeviceIdentity.deviceIDKey), first)
    }

    func testPairingCodeIsSixDigits() {
        for _ in 0..<200 {
            let code = DeviceIdentity.makePairingCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy(\.isNumber))
            XCTAssertNotNil(Int(code))
        }
    }
}
