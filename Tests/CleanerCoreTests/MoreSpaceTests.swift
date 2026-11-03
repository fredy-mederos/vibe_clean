import Foundation
import Testing
@testable import CleanerCore

/// Places that used to go unseen: old AI conversations, browser and current IDE caches, folders of videos.
@Suite struct MoreSpaceTests {
    func context(_ home: TestHome, largeFileMinimumSize: Int64 = 500_000_000) -> ScanContext {
        ScanContext(home: home.url, projectLocations: [], applicationFolders: [], runsSystemCommands: false, largeFileMinimumSize: largeFileMinimumSize)
    }

    func setModified(_ url: URL, daysAgo: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
    }

    func removed(_ item: CleanupItem?, relativeTo home: TestHome) -> Set<String> {
        guard case .removePaths(let urls) = item?.action else { return [] }
        return Set(urls.map { String($0.standardizedFileURL.path.dropFirst(home.url.standardizedFileURL.path.count + 1)) })
    }

    /// A scanner with a probe per worktree doesn't hold back the temp folder's few big items.
    @Test func probesTakeTurnsAcrossScanners() {
        let order = ScanEngine.interleaved([(2, ["temp"]), (0, ["w1", "w2", "w3"]), (1, ["x1", "x2"])]).map(\.1)
        #expect(order == ["w1", "x1", "temp", "w2", "x2", "w3"])
    }

    // MARK: AI coding tools

    @Test func oldConversationsOnlyAndNeverMemory() throws {
        let home = try TestHome()
        let project = ".claude/projects/-Users-me-dev-app"
        try setModified(try home.file("\(project)/old.jsonl", bytes: 1_000_000), daysAgo: 40)
        try home.file("\(project)/old/subagents/agent-1.jsonl", bytes: 500_000)
        try home.file("\(project)/recent.jsonl", bytes: 1_000_000)
        try home.file("\(project)/memory/MEMORY.md")
        try setModified(try home.file(".codex/sessions/2026/08/01/rollout-a.jsonl", bytes: 1_000_000), daysAgo: 90)
        try home.file(".codex/sessions/2026/11/03/rollout-b.jsonl", bytes: 1_000_000)

        let items = AIToolsScanner().items(in: context(home))
        let claude = try #require(items.first { $0.id == "ai.claude.conversations" })
        #expect(removed(claude, relativeTo: home) == ["\(project)/old.jsonl", "\(project)/old"])
        #expect(claude.safety == .review)
        #expect(claude.costLevel == .dataLoss)
        #expect(claude.detail == "1 conversation older than 30 days")
        let codex = try #require(items.first { $0.id == "ai.codex.conversations" })
        #expect(removed(codex, relativeTo: home) == [".codex/sessions/2026/08/01/rollout-a.jsonl"])
    }

    /// Someone who told Claude Code to keep conversations for a year keeps them for a year here too.
    @Test func claudeCodeKeepsWhatItsSettingsKeep() throws {
        let home = try TestHome()
        try home.file(".claude/settings.json", contents: #"{"cleanupPeriodDays": 365}"#)
        try setModified(try home.file(".claude/projects/-Users-me-dev-app/old.jsonl", bytes: 1_000_000), daysAgo: 40)
        #expect(AIToolsScanner().claudeCodeConversations(context(home)) == nil)
    }

    // MARK: Browsers

    @Test func browserCachesForEveryProfile() throws {
        let home = try TestHome()
        try home.file("Library/Caches/Google/Chrome/Default/Cache/Cache_Data/data_1", bytes: 1_000_000)
        try home.file("Library/Caches/Google/Chrome/Profile 1/Code Cache/js/index", bytes: 1_000_000)
        try home.file("Library/Application Support/Google/Chrome/Default/History", bytes: 1_000_000)

        let items = BrowserCachesScanner().items(in: context(home))
        #expect(items.map(\.title) == ["Google Chrome cache"])
        #expect(removed(items.first, relativeTo: home) == ["Library/Caches/Google/Chrome"])
        #expect(items.first?.blockers == [Blocker(name: "Google Chrome", bundleIDs: ["com.google.Chrome"])])
        #expect(items.first?.safety == .safe)
    }

    // MARK: IDEs

    @Test func currentIDEIndexesButNotItsLocalHistory() throws {
        let home = try TestHome()
        let caches = "Library/Caches/Google/AndroidStudio2026.2.1"
        try home.file("\(caches)/index/x", bytes: 1_000_000)
        try home.file("\(caches)/caches/y", bytes: 1_000_000)
        try home.file("\(caches)/LocalHistory/changes.storageData", bytes: 1_000_000)
        try home.file("Library/Application Support/Google/AndroidStudio2026.2.1/options/other.xml")

        let item = try #require(IDEScanner().items(in: context(home)).first { $0.id == "ide.caches:AndroidStudio2026.2.1" })
        #expect(removed(item, relativeTo: home) == ["\(caches)/index", "\(caches)/caches"])
        #expect(item.safety == .safe)
        #expect(item.blockers == [.androidStudio])
        #expect(IDEScanner.blocker(for: .init(product: "WebStorm", version: "2026.1")).processPattern == "WebStorm.app/Contents/MacOS")
    }

    // MARK: Videos

    @Test func foldersOfVideosThatAddUpButNotProjectAssets() throws {
        let home = try TestHome()
        for name in ["a", "b", "c"] {
            try home.file("Desktop/Screen Recordings/\(name).mov", bytes: 1_200_000)
            try home.file("Documents/site/capture/\(name).mp4", bytes: 1_200_000)    // a project's assets
        }
        try home.folder("Documents/site/.git")
        try home.file("Desktop/Screen Recordings/notes.txt", bytes: 1_200_000)
        try home.file("Movies/one.mov", bytes: 1_200_000)                            // a single video, not a folder of them

        let scanner = LargeFilesScanner(mediumVideoSize: 1_000_000, videoFolderSize: 3_000_000)
        let items = scanner.largeFiles(context(home, largeFileMinimumSize: 2_000_000))
        #expect(items.map(\.title) == ["3 videos in Screen Recordings"])
        let item = try #require(items.first)
        #expect(item.safety == .personal)
        #expect(item.action.movesToTrash)
        #expect(item.detail == "Videos · ~/Desktop/Screen Recordings")
    }
}
