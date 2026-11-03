import Foundation
import Testing
@testable import CleanerCore

@Suite struct ArtifactRuleTests {
    func artifacts(in home: TestHome, _ project: String) -> Set<String> {
        let root = home.path(project).standardizedFileURL.pathComponents.count
        return Set(ProjectArtifacts.findArtifacts(in: home.path(project)).map {
            $0.standardizedFileURL.pathComponents.dropFirst(root).joined(separator: "/")
        })
    }

    @Test func nugetPackagesOnlyNextToASolution() throws {
        let home = try TestHome()
        try home.file("dotnet/App.sln")
        try home.file("dotnet/packages/Xamarin.Forms/lib.dll")
        try home.file("dotnet/App/App.csproj")
        try home.file("dotnet/App/bin/Debug/App.dll")
        try home.file("dotnet/App/obj/project.assets.json")
        try home.file("monorepo/package.json")
        try home.file("monorepo/packages/ui/src/index.ts")       // your source code
        #expect(artifacts(in: home, "dotnet") == ["packages", "App/bin", "App/obj"])
        #expect(artifacts(in: home, "monorepo").isEmpty)
    }

    @Test func rubyGemsOnlyInVendorBundleNextToAGemfile() throws {
        let home = try TestHome()
        try home.file("ios/Gemfile")
        try home.file("ios/App.xcodeproj/project.pbxproj")
        try home.file("ios/vendor/bundle/ruby/3.3.0/gems/cocoapods/x.rb")
        try home.file("ios/vendor/HandMade/thing.swift")         // not a gem folder
        try home.file("other/package.json")
        try home.file("other/vendor/bundle/x.rb")                 // no Gemfile
        #expect(artifacts(in: home, "ios") == ["vendor/bundle"])
        #expect(artifacts(in: home, "other").isEmpty)
    }

    @Test func flutterGeneratedFrameworks() throws {
        let home = try TestHome()
        try home.file("app/pubspec.yaml", contents: "flutter:\n")
        try home.file("app/ios/Flutter/Flutter.framework/Flutter", bytes: 10)
        try home.file("app/ios/Flutter/App.framework/App", bytes: 10)
        try home.file("app/ios/Flutter/Generated.xcconfig")
        try home.file("app/macos/Flutter/ephemeral/x")
        try home.file("app/ios/.symlinks/plugins/x")
        try home.file("native/App.xcodeproj/project.pbxproj")
        try home.file("native/Flutter/Flutter.framework/Flutter")  // not in a Flutter project
        #expect(artifacts(in: home, "app") == [
            "ios/Flutter/Flutter.framework", "ios/Flutter/App.framework", "macos/Flutter/ephemeral", "ios/.symlinks",
        ])
        #expect(artifacts(in: home, "native").isEmpty)
    }

    @Test func elixirPythonAndJavaScriptExtras() throws {
        let home = try TestHome()
        try home.file("ex/mix.exs")
        try home.file("ex/_build/dev/x.beam")
        try home.file("ex/deps/jason/mix.exs")
        try home.file("py/pyproject.toml")
        try home.file("py/.venv/lib/python3.13/site.py")
        try home.file("web/package.json")
        try home.file("web/dist/index.js")
        try home.file("web/coverage/lcov.info")
        try home.file("web/.playwright-cli/console.log")
        try home.file("web/playwright.config.ts")
        try home.file("web/test-results/x.png")
        try home.file("web/playwright-report/index.html")
        #expect(artifacts(in: home, "ex") == ["_build", "deps"])
        #expect(artifacts(in: home, "py") == [".venv"])
        #expect(artifacts(in: home, "web") == ["dist", "coverage", ".playwright-cli", "test-results", "playwright-report"])
    }

    /// `xcodebuild -derivedDataPath build/DerivedData` puts DerivedData anywhere, under any name.
    @Test func derivedDataFoundByWhatXcodePutsInIt() throws {
        let home = try TestHome()
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>WorkspacePath</key><string>/x/App.xcodeproj</string></dict></plist>
            """
        try home.file("app/ios/App.xcodeproj/project.pbxproj")
        try home.file("app/ios/build/app-icons.png")                    // yours: build/ itself stays
        for name in ["DerivedData", "DeviceData"] {
            try home.file("app/ios/build/\(name)/info.plist", contents: plist)
            try home.file("app/ios/build/\(name)/Build/Products/Debug-iphonesimulator/App.app/App")
            try home.file("app/ios/build/\(name)/Logs/Build/LogStoreManifest.plist")
        }
        try home.file("app/notes/info.plist", contents: "<plist version=\"1.0\"><dict/></plist>")  // no workspace
        try home.file("app/notes/Build/x")
        try home.file("app/notes/Logs/x")
        #expect(artifacts(in: home, "app") == ["ios/build/DerivedData", "ios/build/DeviceData"])
        #expect(ProjectArtifacts.kind(of: home.path("app/ios/build/DeviceData")) == "DerivedData")
        #expect(ProjectArtifacts.kind(of: home.path("app/notes")) == "notes")
    }

    @Test func newMarkersFindProjects() throws {
        let home = try TestHome()
        try home.file("code/restaurant/App.sln")
        try home.file("code/symphony/elixir/mix.exs")
        let names = Set(ProjectDiscovery.findProjects(in: [home.path("code")], maxDepth: 5).map(\.lastPathComponent))
        #expect(names == ["restaurant", "elixir"])
    }
}
