import Foundation

/// Linked git worktrees: extra checkouts of your repositories, which Claude Code, Codex, Cursor and Conductor make
/// for each task. Each one has its own build outputs, so together they get big.
///
/// A worktree is only removed when nothing in it would be lost: everything committed is in the repository's main
/// branch (merged, rebased or squashed) and nothing is uncommitted (`GitWorktrees`). It's removed with
/// `git worktree remove` and its branch stays. It's only Safe when it also has no git-ignored files of its own
/// (renders, captures) and nothing has it open or used it lately. Other worktrees are kept, and their git-ignored
/// build folders are offered instead.
public struct WorktreesScanner: CleanupScanner {
    public let categoryID = "worktrees"
    public let title = "Git worktrees"
    public let symbol = "arrow.triangle.branch"
    /// Listed by last use, so the ones you haven't touched in a while come first.
    public var sortsByLastUsed: Bool { true }

    /// A merged worktree used more recently than this may still be open in a session or editor, so it's Review.
    let inUseWithin: TimeInterval

    public init(inUseWithin: TimeInterval = 2 * 86_400) {
        self.inUseWithin = inUseWithin
    }

    public func probes(in context: ScanContext) -> [ItemProbe] {
        guard context.runsSystemCommands else { return [] }
        let openFiles = OpenFiles.current()
        return GitWorktrees.find(in: context.allProjects(), home: context.home)
            .filter { (try? PathGuard.validate($0.path, home: context.home)) != nil }
            .map { entry in
                .one {
                    GitWorktrees.inspect(entry).flatMap { item(for: $0, openBy: openFiles?.processes(using: $0.path) ?? []) }
                }
            }
    }

    /// What's offered for a worktree: all of it when it's merged, otherwise its build folders, if any.
    /// - Parameter openBy: names of the processes that have something in it open.
    public func item(for info: WorktreeInfo, openBy: [String] = []) -> CleanupItem? {
        info.canBeRemoved ? removal(of: info, openBy: openBy) : buildFolders(of: info)
    }

    /// The whole worktree, removed with git. Review when it has ignored files of its own, or may still be open.
    func removal(of info: WorktreeInfo, openBy: [String] = [], now: Date = Date()) -> CleanupItem {
        let base = info.base ?? "main"
        let merged = switch info.merge {
        case .rebased?: "Its commits were rebased into \(base)"
        case .squashed?: "Its commits were squashed into \(base)"
        case .sameFiles?: "\(base) has the same version of every file it changed"
        case .contained?, nil: "Everything committed in it is in \(base)"
        }
        var reason = "\(info.summary). \(merged), and nothing is uncommitted."
        var details = ["Merged into \(base)"]
        var cost = "Its build outputs and other ignored files go with it"
        var costLevel = CostLevel.rebuild

        let lastUsed = info.lastActivity.flatMap { now.timeIntervalSince($0) < inUseWithin ? $0 : nil }
        if !openBy.isEmpty {
            reason += " It's open right now in \(Self.list(openBy, limit: 3))."
            details.append("open in \(openBy[0])")
            cost = "\(Self.list(openBy, limit: 3)) loses the folder it has open"
            costLevel = .loseOption
        } else if let lastUsed {
            reason += " It was used \(lastUsed.formatted(.relative(presentation: .named))), so a session or editor may still have it open."
            cost = "If a session or editor still has it open, it loses its folder"
            costLevel = .loseOption
        }
        if let own = info.ownIgnoredFiles {
            if !own.isEmpty {
                let files = ProjectFacts.count(own.count, "file")
                reason += " It also has \(files) git ignores that the main checkout doesn't have (\(Self.list(own, limit: 2))), "
                    + "and removing it deletes them."
                details.append("\(files) only it has")
                cost = "\(files) only it has \(own.count == 1 ? "is" : "are") deleted with it"
                costLevel = .dataLoss
            }
        } else {
            reason += " Its git-ignored files couldn't all be compared with the main checkout, so check them first."
            cost = "Ignored files only it has are deleted with it"
            costLevel = .dataLoss
        }
        let isSafe = openBy.isEmpty && lastUsed == nil && info.ownIgnoredFiles?.isEmpty == true
        return CleanupItem(
            id: "worktree:\(info.path.path)",
            title: info.name,
            detail: details.joined(separator: " · "),
            size: DirectorySize.reclaimableSize(of: info.path),
            safety: isSafe ? .safe : .review,
            action: .removeWorktree(gitDir: info.gitDir, worktree: info.path, head: info.head),
            reason: reason,
            cost: cost,
            costLevel: costLevel,
            afterCleaning: info.branch.map { "Removed with git worktree remove. The branch \($0) stays, and git worktree add brings the folder back." }
                ?? "Removed with git worktree remove. Its commits stay in \(base).",
            revealURL: info.path,
            lastUsed: info.lastActivity,
            worktree: info
        )
    }

    /// "a, b and 3 more".
    static func list(_ names: [String], limit: Int) -> String {
        let shown = Array(names.prefix(limit))
        if names.count > limit { return shown.joined(separator: ", ") + " and \(names.count - limit) more" }
        guard let last = shown.last, shown.count > 1 else { return shown.first ?? "" }
        return shown.dropLast().joined(separator: ", ") + " and " + last
    }

    /// A worktree that's kept: only its build folders that git ignores, as for any project.
    func buildFolders(of info: WorktreeInfo) -> CleanupItem? {
        guard let folders = ProjectsScanner.BuildFolders(in: info.path, runsGit: true), folders.checkedWithGit else { return nil }
        return CleanupItem(
            id: "worktree-build:\(info.path.path)",
            title: info.name,
            detail: "Build folders only · \(info.keptSummary)",
            size: DirectorySize.reclaimableSize(of: folders.urls),
            safety: .safe,
            action: .removePaths(folders.urls),
            reason: "Build outputs (\(folders.kinds)) in this \(info.repositoryName) worktree, all ignored by git. "
                + "The worktree itself stays because \(info.keptBecause).",
            cost: folders.cost(of: "this worktree"),
            costLevel: folders.costLevel,
            afterCleaning: "Build tools recreate these the next time you build. The worktree, its commits and its changes stay.",
            revealURL: info.path,
            lastUsed: info.lastActivity,
            worktree: info,
            checkedWithGit: true,
            skipped: folders.skipped
        )
    }
}
