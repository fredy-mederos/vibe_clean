import Foundation
import Testing
@testable import CleanerCore

@Suite struct SimulatorTests {
    @Test func unavailableSimulatorsAreDeletedByID() throws {
        let home = try TestHome()
        try home.file("Library/Developer/CoreSimulator/Devices/BBB/data/x", bytes: 1_000_000)
        try home.file("Library/Developer/CoreSimulator/Devices/AAA/data/x", bytes: 1_000_000)
        let devices = [
            SimulatorDevice(udid: "BBB", name: "iPhone Air", isAvailable: false, runtimeIdentifier: "iOS-26-5"),
            SimulatorDevice(udid: "AAA", name: "iPhone 17e", isAvailable: false, runtimeIdentifier: "iOS-26-5"),
            SimulatorDevice(udid: "CCC", name: "iPhone 17", isAvailable: true, runtimeIdentifier: "iOS-27-0"),
        ]
        let context = ScanContext(home: home.url, projectLocations: [], runsSystemCommands: false)
        let item = try #require(XcodeScanner.unavailableSimulatorsItem(devices, context: context))
        // `simctl delete unavailable` skips simulators whose runtime was removed, so name each one.
        #expect(item.action == .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "AAA", "BBB"]))
        #expect(item.detail == "2 simulators whose iOS version is no longer installed")
        #expect(item.size >= 2_000_000)
    }

    @Test func bigSimulatorDataIsErasedButNotWhileRunning() throws {
        let home = try TestHome()
        let data = try home.folder("Library/Developer/CoreSimulator/Devices/DDD/data")
        try home.file("Library/Developer/CoreSimulator/Devices/DDD/data/Containers/app.db", bytes: 2_000_000)
        let device = SimulatorDevice(
            udid: "DDD", name: "iPhone 17 Pro", isAvailable: true, runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            state: "Shutdown", dataPath: data, lastUsed: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let item = try #require(XcodeScanner.simulatorDataItem(device, minimumSize: 1_000_000))
        #expect(item.action == .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "erase", "DDD"]))
        #expect(item.safety == .review)
        #expect(item.costLevel == .dataLoss)
        #expect(item.detail == "Apps and their data · iOS 26.5")

        var running = device
        running.state = "Booted"
        #expect(XcodeScanner.simulatorDataItem(running, minimumSize: 1_000_000) == nil)
        var small = device
        small.dataPath = try home.folder("Library/Developer/CoreSimulator/Devices/EEE/data")
        #expect(XcodeScanner.simulatorDataItem(small, minimumSize: 1_000_000) == nil)
    }

    @Test func readsDeviceDataFromSimctl() throws {
        let json = """
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-2": [{"udid": "DDD", "name": "iPad Pro 13-inch (M5)",
              "isAvailable": true, "state": "Shutdown", "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/DDD/data",
              "dataPathSize": 3430000000, "lastUsedAt": "2026-10-31T07:12:01Z"}]}}
            """
        let device = try #require(SimulatorDevices.parse(json: Data(json.utf8)).first)
        #expect(device.dataPath?.path == "/Users/me/Library/Developer/CoreSimulator/Devices/DDD/data")
        #expect(device.lastUsed == ISO8601DateFormatter().date(from: "2026-10-31T07:12:01Z"))
        #expect(device.state == "Shutdown")
        #expect(SimulatorDevice.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4") == "iOS 27.2")
    }

    @Test func nothingToDoWhenAllAreAvailable() {
        let devices = [SimulatorDevice(udid: "CCC", name: "iPhone 17", isAvailable: true, runtimeIdentifier: "iOS-27-0")]
        let context = ScanContext(home: URL(fileURLWithPath: "/tmp"), projectLocations: [], runsSystemCommands: false)
        #expect(XcodeScanner.unavailableSimulatorsItem(devices, context: context) == nil)
    }
}
