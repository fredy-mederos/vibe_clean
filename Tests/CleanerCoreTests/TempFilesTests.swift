import Foundation
import Testing
@testable import CleanerCore

/// Uses a fake temp folder inside the fake home: the real one is never read.
@Suite struct TempFilesTests {
    let daysAgo: (Double) -> Date = { Date().addingTimeInterval(-$0 * 86_400) }

    func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// What an item removes, by name: the temp folder's contents come back as /private/var/….
    func removedNames(_ item: CleanupItem?) -> [String] {
        guard case .removePaths(let urls) = item?.action else { return [] }
        return urls.map(\.lastPathComponent)
    }

    func items(_ home: TestHome, temp: URL) -> [String: CleanupItem] {
        let context = ScanContext(home: home.url, projectLocations: [], runsSystemCommands: false, temporaryDirectory: temp)
        let items = TempFilesScanner(otherMinimumSize: 1_000_000).items(in: context)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    @Test func groupsLeftoversOfKnownToolsAndSkipsRecentOnes() throws {
        let home = try TestHome()
        let temp = try home.folder("var/T")
        try home.file("var/T/remotion-webpack-bundle-l6uMQV/public/video.mp4", bytes: 2_000_000)
        try home.file("var/T/remotion-v4.0.535-assetsb7mc8xi80b/image.png", bytes: 1_000_000)
        try home.file("var/T/remotion-webpack-bundle-NOWnow/public/video.mp4", bytes: 2_000_000)   // rendering now
        try home.file("var/T/instrumentscbYY0b.ktrace", bytes: 1_500_000)
        try home.file("var/T/XcodeDistPipeline.~~~f8AeVG/Payload/App.ipa", bytes: 1_200_000)
        for name in ["remotion-webpack-bundle-l6uMQV", "remotion-v4.0.535-assetsb7mc8xi80b", "instrumentscbYY0b.ktrace",
                     "XcodeDistPipeline.~~~f8AeVG"] {
            try setModified(temp.appendingPathComponent(name), daysAgo(2))
        }

        let found = items(home, temp: temp)
        let remotion = try #require(found["temp:remotion"])
        #expect(remotion.safety == .safe)
        #expect(remotion.detail == "2 folders in the temp folder")
        #expect(removedNames(remotion) == ["remotion-v4.0.535-assetsb7mc8xi80b", "remotion-webpack-bundle-l6uMQV"])
        #expect(remotion.size >= 3_000_000)
        #expect(remotion.blockers == [.remotion])
        #expect(found["temp:instruments"]?.blockers == [.instruments])
        #expect(found["temp:xcode-export"]?.blockers == [.xcode])
    }

    @Test func listsOtherBigFilesOnlyWhenNothingChangedThemForDays() throws {
        let home = try TestHome()
        let temp = try home.folder("var/T")
        try setModified(try home.file("var/T/old-render.mov", bytes: 2_000_000), daysAgo(5))
        try setModified(try home.file("var/T/fresh-render.mov", bytes: 2_000_000), daysAgo(1))
        try setModified(try home.file("var/T/small.log", bytes: 10_000), daysAgo(5))
        try home.file("var/T/com.apple.mediaanalysisd/cache.db", bytes: 2_000_000)
        try setModified(temp.appendingPathComponent("com.apple.mediaanalysisd"), daysAgo(5))

        let found = items(home, temp: temp)
        #expect(found.values.flatMap(removedNames) == ["old-render.mov"])
        let old = try #require(found.values.first)
        #expect(old.safety == .review)
        #expect(old.costLevel == .dataLoss)
    }

    @Test func nothingWithoutATempFolder() throws {
        let home = try TestHome()
        let context = ScanContext(home: home.url, projectLocations: [], runsSystemCommands: false)
        #expect(TempFilesScanner().probes(in: context).isEmpty)
    }

    @Test func pathGuardAllowsOnlyWhatIsInsideTheTempFolder() throws {
        let home = try TestHome()
        let temp = try home.folder("var/T")
        let outsideHome = URL(fileURLWithPath: "/private/var/folders/xx/yy/C/clang")
        try PathGuard.validate(temp.appendingPathComponent("remotion-webpack-bundle-x"), home: outsideHome, temporaryDirectory: temp)
        try PathGuard.validate(try home.folder("var/T/a").appendingPathComponent("b"), home: outsideHome, temporaryDirectory: temp)
        #expect(throws: PathGuard.Violation.self) {
            try PathGuard.validate(temp, home: outsideHome, temporaryDirectory: temp)
        }
        #expect(throws: PathGuard.Violation.self) {
            try PathGuard.validate(temp.appendingPathComponent("../escape"), home: outsideHome, temporaryDirectory: temp)
        }
        #expect(throws: PathGuard.Violation.self) {
            try PathGuard.validate(temp.appendingPathComponent("x"), home: outsideHome)
        }
    }

    /// A link to the temp folder, like /var → /private/var, still counts as inside it.
    @Test func pathGuardComparesRealPaths() throws {
        let home = try TestHome()
        let temp = try home.folder("private/var/T")
        try FileManager.default.createSymbolicLink(at: home.path("var"), withDestinationURL: home.path("private/var"))
        let elsewhere = URL(fileURLWithPath: "/nowhere")
        try PathGuard.validate(home.path("var/T/bundle"), home: elsewhere, temporaryDirectory: temp)
        try PathGuard.validate(temp.appendingPathComponent("bundle"), home: elsewhere, temporaryDirectory: home.path("var/T"))
    }

    @Test func cleanerRemovesLeftoversInTheTempFolder() throws {
        let home = try TestHome()
        let temp = try home.folder("var/T")
        let bundle = try home.file("var/T/remotion-webpack-bundle-abc/public/video.mp4", bytes: 2_000_000)
            .deletingLastPathComponent().deletingLastPathComponent()
        try setModified(bundle, daysAgo(2))
        let item = try #require(items(home, temp: temp)["temp:remotion"])
        let elsewhere = try home.folder("home")

        #expect(Cleaner(home: elsewhere).clean(item).succeeded == false)
        #expect(FileInfo.exists(bundle))
        #expect(Cleaner(home: elsewhere, temporaryDirectory: temp).clean(item).succeeded)
        #expect(!FileInfo.exists(bundle))
        #expect(FileInfo.exists(temp))
    }

    @Test func userTempFolderIsTheOneMacOSGivesThisAccount() throws {
        let temp = try #require(TemporaryFolder.user)
        #expect(FileInfo.realPath(temp)?.hasPrefix("/private/var/folders/") == true)
        #expect(temp.lastPathComponent == "T")
        #expect(PathFormat.abbreviated(temp.appendingPathComponent("remotion-webpack-bundle-x"), home: URL(fileURLWithPath: "/nowhere"))
            == "$TMPDIR/remotion-webpack-bundle-x")
    }
}
