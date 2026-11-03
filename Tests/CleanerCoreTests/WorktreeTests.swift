import Foundation
import Testing
@testable import CleanerCore

@Suite struct WorktreeTests {
    @discardableResult
    func git(_ dir: URL, _ arguments: [String]) throws -> String {
        let output = try CommandRunner.run("/usr/bin/git", ["-C", dir.path, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + arguments)
        #expect(output.status == 0, "git \(arguments.joined(separator: " ")): \(output.stderr)")
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Node project with one commit on main. `src.txt` has 20 numbered lines to change.
    func repo(in home: TestHome, at relative: String = "dev/app") throws -> URL {
        let repo = try home.folder(relative)
        try home.file("\(relative)/package.json", contents: "{}")
        try home.file("\(relative)/.gitignore", contents: "node_modules/\n")
        try home.file("\(relative)/src.txt", contents: (1...20).map { "line \($0)\n" }.joined())
        try git(repo, ["init", "-q", "-b", "main"])
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-q", "-m", "init"])
        return repo
    }

    /// A worktree on a new branch (Claude Code's place by default), with an ignored node_modules.
    @discardableResult
    func worktree(_ name: String, of repo: URL, at path: URL? = nil, detached: Bool = false) throws -> URL {
        let path = path ?? repo.appendingPathComponent(".claude/worktrees/\(name)")
        try git(repo, ["worktree", "add", "-q"] + (detached ? ["--detach"] : ["-b", name]) + [path.path])
        try FileManager.default.createDirectory(at: path.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2_000_000).write(to: path.appendingPathComponent("node_modules/x.js"))
        return path
    }

    /// Replaces line `number` of `src.txt` and commits.
    func change(line number: Int, to text: String, in checkout: URL) throws {
        let file = checkout.appendingPathComponent("src.txt")
        var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[number - 1] = text
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try git(checkout, ["commit", "-q", "-am", "Change line \(number)"])
    }

    func items(in home: TestHome, inUseWithin: TimeInterval = 0) -> [String: CleanupItem] {
        let context = ScanContext(home: home.url, projectLocations: [home.path("dev")], runsSystemCommands: true)
        return Dictionary(uniqueKeysWithValues: WorktreesScanner(inUseWithin: inUseWithin).items(in: context).map { ($0.title, $0) })
    }

    func info(_ worktree: URL, in home: TestHome) throws -> WorktreeInfo {
        let entry = try #require(GitWorktrees.find(in: [home.path("dev/app")], home: home.url).first { $0.path.path == worktree.path })
        return try #require(GitWorktrees.inspect(entry))
    }

    // MARK: Finding

    @Test func findsWorktreesWhereverTheyAreButNotTheMainCheckout() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        try worktree("feat", of: repo)
        try worktree("hotfix", of: repo, at: home.path("dev/app-hotfix"))
        try worktree("codex", of: repo, at: home.path(".codex/worktrees/ab12/app"), detached: true)
        // A repository outside the project folders, found through the worktree Codex keeps for it.
        let other = try self.repo(in: home, at: "elsewhere/other")
        try worktree("x", of: other, at: home.path(".codex/worktrees/cd34/other"))

        let found = GitWorktrees.find(in: [repo], home: home.url)
        let names = Set(found.compactMap(GitWorktrees.inspect).map { "\($0.repositoryName): \($0.name) [\($0.tool ?? "-")]" })
        #expect(names == ["app: feat [Claude Code]", "app: app-hotfix [-]", "app: app (ab12) [Codex]", "other: x [Codex]"])
    }

    @Test func readsRelativeLinks() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        let path = home.path("dev/app-relative")
        try git(repo, ["-c", "worktree.useRelativePaths=true", "worktree", "add", "-q", "-b", "relative", path.path])
        #expect(GitWorktrees.find(in: [repo], home: home.url).map(\.path.path) == [path.path])
        #expect(GitWorktrees.isInLinkedWorktree(path, home: home.url))
        #expect(!GitWorktrees.isInLinkedWorktree(repo, home: home.url))
    }

    // MARK: Merged

    @Test func mergedWorktreeIsRemovedWhole() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        let feat = try worktree("feat", of: repo)
        try change(line: 3, to: "line 3 feat", in: feat)
        try git(repo, ["merge", "-q", "--ff-only", "feat"])
        try worktree("fresh", of: repo)   // nothing committed yet

        let items = items(in: home)
        let item = try #require(items["feat"])
        #expect(item.safety == .safe)
        #expect(item.detail == "Merged into main")
        #expect(item.reason?.hasPrefix("Claude Code worktree of app, on feat. Everything committed in it is in main") == true)
        #expect(item.size >= 2_000_000)
        guard case .removeWorktree(let gitDir, let worktree, let head) = item.action else { Issue.record("expected removeWorktree"); return }
        #expect(gitDir.path == repo.appendingPathComponent(".git").path)
        #expect(worktree.path == feat.path)
        #expect(head == (try git(feat, ["rev-parse", "HEAD"])))
        #expect(items["fresh"]?.action.removesWorktree == true)
    }

    @Test func rebasedWorkCountsAsMergedEvenWhenGitCherryMissesIt() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        let rebased = try worktree("rebased", of: repo)
        try change(line: 10, to: "line 10 rebased", in: rebased)
        // Main changes a line next to it first, so the picked commit has different context lines.
        try change(line: 7, to: "line 7 main", in: repo)
        try git(repo, ["cherry-pick", "rebased"])

        #expect(try git(repo, ["cherry", "main", "rebased"]).hasPrefix("+"))
        #expect(try info(rebased, in: home).merge == .rebased)
    }

    @Test func squashMergedWorkCountsAsMerged() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        let squashed = try worktree("squashed", of: repo)
        try change(line: 15, to: "line 15 squashed", in: squashed)
        try change(line: 18, to: "line 18 squashed", in: squashed)
        // Only touches a file of its own, so main ends up with the same version of it.
        let same = try worktree("same", of: repo)
        try Data("draft\n".utf8).write(to: same.appendingPathComponent("notes.txt"))
        try git(same, ["add", "notes.txt"])
        try git(same, ["commit", "-q", "-m", "Add notes"])
        try Data("final\n".utf8).write(to: same.appendingPathComponent("notes.txt"))
        try git(same, ["commit", "-q", "-am", "Finish notes"])
        for branch in ["squashed", "same"] {
            try git(repo, ["merge", "-q", "--squash", branch])
            try git(repo, ["commit", "-q", "-m", "Squashed \(branch)"])
        }
        #expect(try info(same, in: home).merge == .sameFiles)

        // Once main changes those lines again, only the squash commit's changes still match.
        try change(line: 15, to: "line 15 later", in: repo)
        #expect(try info(squashed, in: home).merge == .squashed)
    }

    @Test func recentlyUsedMergedWorktreeIsReview() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        try worktree("busy", of: repo)
        let item = try #require(items(in: home, inUseWithin: 3600)["busy"])
        #expect(item.safety == .review)
        #expect(item.costLevel == .loseOption)
        #expect(item.reason?.contains("may still have it open") == true)
        #expect(item.action.removesWorktree)
    }

    // MARK: Merged, but not Safe

    /// Renders git ignores go with the worktree, unless the main checkout has the same file (copied or cloned).
    @Test func mergedWorktreeWithIgnoredFilesOfItsOwnIsOnlyForReview() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        try home.file("dev/app/.gitignore", contents: "node_modules/\nout/\n.env\n.DS_Store\n.idea/\nios/build/\nlocal.properties\npackage-lock.json\n")
        try git(repo, ["commit", "-q", "-am", "Ignore more"])
        try home.file("dev/app/.env", contents: "TOKEN=1\n")
        let intro = try home.file("dev/app/out/intro.mp4", bytes: 300_000)

        let copied = try worktree("copied", of: repo)
        try home.file("dev/app/.claude/worktrees/copied/.env", contents: "TOKEN=1\n")
        try home.folder("dev/app/.claude/worktrees/copied/out")
        try #require(clonefile(intro.path, copied.appendingPathComponent("out/intro.mp4").path, 0) == 0)
        try home.file("dev/app/.claude/worktrees/copied/.DS_Store")
        try home.file("dev/app/.claude/worktrees/copied/.idea/workspace.xml")
        try home.file("dev/app/.claude/worktrees/copied/ios/build/DerivedData/Build/x.o", bytes: 100_000)
        try home.file("dev/app/.claude/worktrees/copied/package-lock.json", contents: "{}")
        // What Android Studio writes into every checkout it opens.
        try home.file("dev/app/.claude/worktrees/copied/local.properties", contents: "## Generated by Android Studio\nsdk.dir=/Users/me/Library/Android/sdk\n")

        let rendered = try worktree("rendered", of: repo)
        try home.file("dev/app/.claude/worktrees/rendered/.env", contents: "TOKEN=2\n")
        try home.file("dev/app/.claude/worktrees/rendered/out/intro.mp4", bytes: 300_000)
        try home.file("dev/app/.claude/worktrees/rendered/out/final.mp4", bytes: 500_000)
        try home.file("dev/app/.claude/worktrees/rendered/local.properties", contents: "sdk.dir=/Users/me/sdk\nSIGNING_KEY=abc\n")

        #expect(try info(copied, in: home).ownIgnoredFiles == [])
        #expect(try info(rendered, in: home).ownIgnoredFiles == ["out/final.mp4", "local.properties", ".env"])
        let items = items(in: home)
        #expect(items["copied"]?.safety == .safe)
        let item = try #require(items["rendered"])
        #expect(item.safety == .review)
        #expect(item.costLevel == .dataLoss)
        #expect(item.detail == "Merged into main · 3 files only it has")
        #expect(item.reason?.contains("It also has 3 files git ignores that the main checkout doesn't have (out/final.mp4, local.properties and 1 more)") == true)
        #expect(item.action.removesWorktree)
    }

    @Test func mergedWorktreeOpenSomewhereIsOnlyForReview() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        let feat = try worktree("feat", of: repo)
        let item = try #require(WorktreesScanner(inUseWithin: 0).item(for: try info(feat, in: home), openBy: ["claude", "zsh"]))
        #expect(item.safety == .review)
        #expect(item.costLevel == .loseOption)
        #expect(item.detail == "Merged into main · open in claude")
        #expect(item.reason?.contains("It's open right now in claude and zsh.") == true)
    }

    @Test func openFilesLeaveOutTheScanAndTheCommandsItRuns() {
        let output = """
            p100
            cclaude
            R1
            fcwd
            n/Users/me/dev/app/.claude/worktrees/feat
            p200
            ckmmc
            R1
            fcwd
            n/Users/me/dev/app/.claude/worktrees/other
            p201
            csh
            R200
            p202
            cgit
            R201
            fcwd
            n/Users/me/dev/app/.claude/worktrees/other
            p400
            cadb
            R1
            fcwd
            n/Users/me/dev/app/.claude/worktrees/feat-2
            p300
            cCode Helper
            R1
            f12r
            n/Users/me/dev/app/.claude/worktrees/feat-2/src/a.swift
            """
        let open = OpenFiles.parse(output, excludingDescendantsOf: 200)
        let worktrees = URL(fileURLWithPath: "/Users/me/dev/app/.claude/worktrees")
        #expect(open.processes(using: worktrees.appendingPathComponent("feat")) == ["claude"])
        #expect(open.processes(using: worktrees.appendingPathComponent("other")).isEmpty)
        #expect(open.processes(using: worktrees.appendingPathComponent("feat-2")) == ["Code Helper"])
        #expect(open.processes(using: worktrees) == ["Code Helper", "claude"])
    }

    @Test func lsofRuns() {
        #expect(OpenFiles.current() != nil)
    }

    // MARK: Kept

    @Test func unmergedOrDirtyWorktreesOnlyOfferTheirBuildFolders() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        let wip = try worktree("wip", of: repo)
        try change(line: 5, to: "line 5 wip", in: wip)
        let dirty = try worktree("dirty", of: repo)
        try Data("idea".utf8).write(to: dirty.appendingPathComponent("notes.txt"))
        let detached = try worktree("detached", of: repo, detached: true)
        try change(line: 6, to: "line 6 detached", in: detached)
        try change(line: 7, to: "line 7 detached", in: detached)
        let bare = try worktree("bare", of: repo)
        try change(line: 8, to: "line 8 bare", in: bare)
        try FileManager.default.removeItem(at: bare.appendingPathComponent("node_modules"))

        let items = items(in: home)
        let kept = try #require(items["wip"])
        #expect(kept.id == "worktree-build:\(wip.path)")
        #expect(kept.safety == .safe)
        #expect(kept.checkedWithGit)
        guard case .removePaths(let urls) = kept.action else { Issue.record("expected paths"); return }
        #expect(urls.map(\.lastPathComponent) == ["node_modules"])
        #expect(kept.detail == "Build folders only · 1 commit not in main")
        #expect(kept.reason?.hasSuffix("The worktree itself stays because 1 commit isn't in main.") == true)

        #expect(items["dirty"]?.reason?.hasSuffix("because it has 1 uncommitted change (notes.txt).") == true)
        #expect(items["detached"]?.detail == "Build folders only · 2 commits not in main")
        // Nothing to clean in a kept worktree without build folders.
        #expect(items["bare"] == nil)
    }

    @Test func lockedWorktreeIsKept() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        let locked = try worktree("locked", of: repo)
        try git(repo, ["worktree", "lock", "--reason", "on a USB disk", locked.path])
        let info = try info(locked, in: home)
        #expect(info.isMerged)
        #expect(!info.canBeRemoved)
        #expect(info.keptSummary == "locked")
        #expect(items(in: home)["locked"]?.action.removesWorktree == false)
    }

    @Test func explainsEverythingThatKeepsAWorktree() {
        var info = WorktreeInfo(path: URL(fileURLWithPath: "/u/dev/app-x"), gitDir: URL(fileURLWithPath: "/u/dev/app/.git"),
                                repositoryName: "app", head: "0c2d7606e742", base: "origin/main")
        info.uncommitted = ["a.txt", "b/c.txt", "d.txt"]
        info.unmergedCommits = 3
        #expect(info.keptSummary == "3 uncommitted changes, 3 commits not in origin/main")
        #expect(info.keptBecause == "it has 3 uncommitted changes (a.txt, b/c.txt and 1 more) and 3 commits aren't in origin/main")
        #expect(info.summary == "Worktree of app, detached at 0c2d760")
    }

    // MARK: Cleaning

    @Test func cleanerRemovesMergedWorktreeWithGitAndKeepsTheBranch() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        let feat = try worktree("feat", of: repo)
        try change(line: 3, to: "line 3 feat", in: feat)
        try git(repo, ["merge", "-q", "--ff-only", "feat"])

        let item = try #require(items(in: home)["feat"])
        let outcome = Cleaner(home: home.url).clean(item)
        #expect(outcome.succeeded, "\(outcome.error ?? "")")
        #expect(!FileManager.default.fileExists(atPath: feat.path))
        #expect(!(try git(repo, ["worktree", "list", "--porcelain"])).contains(feat.lastPathComponent))
        #expect(try git(repo, ["branch", "--list", "feat"]).contains("feat"))
    }

    @Test func cleanerStopsWhenTheWorktreeChangedSinceTheScan() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        let edited = try worktree("edited", of: repo)
        let committed = try worktree("committed", of: repo, detached: true)
        let items = items(in: home)

        try Data("new".utf8).write(to: edited.appendingPathComponent("new.txt"))
        let editedOutcome = Cleaner(home: home.url).clean(try #require(items["edited"]))
        #expect(editedOutcome.error?.contains("untracked") == true, "\(editedOutcome.error ?? "")")
        #expect(FileManager.default.fileExists(atPath: edited.path))

        try change(line: 4, to: "line 4 later", in: committed)
        let committedOutcome = Cleaner(home: home.url).clean(try #require(items["committed"]))
        #expect(committedOutcome.error?.contains("new commits") == true, "\(committedOutcome.error ?? "")")
        #expect(FileManager.default.fileExists(atPath: committed.path))
    }

    @Test func projectsScannerLeavesLinkedWorktreesToTheWorktreeScanner() throws {
        let home = try TestHome()
        let repo = try repo(in: home)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2_000_000).write(to: repo.appendingPathComponent("node_modules/x.js"))
        let hotfix = try worktree("hotfix", of: repo, at: home.path("dev/app-hotfix"))
        try change(line: 2, to: "line 2 hotfix", in: hotfix)

        let context = ScanContext(home: home.url, projectLocations: [home.path("dev")], runsSystemCommands: true)
        #expect(ProjectsScanner().items(in: context).map(\.title) == ["app"])
        #expect(WorktreesScanner().items(in: context).map(\.id) == ["worktree-build:\(hotfix.path)"])
    }
}
