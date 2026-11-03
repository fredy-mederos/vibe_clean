import Foundation

/// Build outputs inside your own projects (`build/`, `node_modules/`, `.gradle/`, `.dart_tool/`...).
/// One item per project so you can choose which projects to clean.
///
/// A folder is only offered as Safe when it passes two checks: it matches an artifact rule
/// (`ProjectArtifacts`), and git ignores it with nothing tracked inside (`GitIgnoreCheck`).
/// Folders git doesn't ignore are left out; projects outside git become Review.
public struct ProjectsScanner: CleanupScanner {
    public let categoryID = "projects"
    public let title = "Project build folders"
    public let symbol = "folder.badge.gearshape"

    public init() {}

    /// Folders that come back through a package install rather than a local build.
    static let downloadedArtifacts: Set<String> = [
        "node_modules", "Pods", ".dart_tool", "bundle", "packages", "deps", ".venv", "venv",
    ]

    public func probes(in context: ScanContext) -> [ItemProbe] {
        // Linked worktrees are listed under Git worktrees, which removes them whole when they're merged.
        let projects = context.allProjects().filter { project in
            !context.runsSystemCommands || !GitWorktrees.isInLinkedWorktree(project, home: context.home)
        }
        return projects.map { project in
            .one {
                guard let folders = BuildFolders(in: project, runsGit: context.runsSystemCommands) else { return nil }
                let location = PathFormat.abbreviated(project, home: context.home)
                return CleanupItem(
                    id: "project:\(project.path)",
                    title: project.lastPathComponent,
                    detail: "\(folders.count): \(folders.kinds)",
                    size: DirectorySize.reclaimableSize(of: folders.urls),
                    safety: folders.checkedWithGit ? .safe : .review,
                    action: .removePaths(folders.urls),
                    reason: folders.checkedWithGit
                        ? "Build outputs (\(folders.kinds)) in \(location), all ignored by git. Your source files aren't touched."
                        : "Build outputs (\(folders.kinds)) in \(location). It isn't a git repository, so git couldn't confirm they're ignored.",
                    cost: folders.cost(of: "this project"),
                    costLevel: folders.costLevel,
                    afterCleaning: "Build tools recreate these the next time you build or install dependencies.",
                    revealURL: project,
                    lastUsed: ProjectArtifacts.lastActivity(of: project),
                    project: ProjectProfiler.profile(of: project, runsGit: context.runsSystemCommands),
                    checkedWithGit: folders.checkedWithGit,
                    skipped: folders.skipped
                )
            }
        }
    }

    /// The build folders in a project that pass both checks, and what cleaning them costs.
    /// Also used for the build folders of worktrees that are kept.
    struct BuildFolders {
        var urls: [URL]
        /// Folders a rule matched but git didn't confirm.
        var skipped: [SkippedFolder]
        /// Git confirmed every folder is ignored with nothing tracked inside. False outside git.
        var checkedWithGit: Bool
        /// "build, .gradle, node_modules".
        var kinds: String
        /// "3 folders".
        var count: String
        var costLevel: CostLevel
        private var names: Set<String>

        init?(in project: URL, runsGit: Bool) {
            let found = ProjectArtifacts.findArtifacts(in: project)
            guard !found.isEmpty else { return nil }
            let git = runsGit
                ? GitIgnoreCheck.check(found, in: project)
                : GitIgnoreCheck.Result(isRepository: false, ignored: [], skipped: [])
            let artifacts = git.isRepository ? git.ignored : found
            guard !artifacts.isEmpty else { return nil }

            urls = artifacts
            skipped = git.skipped
            checkedWithGit = git.isRepository
            names = Set(artifacts.map(ProjectArtifacts.kind(of:)))
            kinds = names.map(ProjectArtifacts.displayName(forFolder:)).sorted().joined(separator: ", ")
            count = artifacts.count == 1 ? "1 folder" : "\(artifacts.count) folders"
            costLevel = names.isDisjoint(with: ProjectsScanner.downloadedArtifacts) ? .rebuild : .redownload
        }

        /// "Next build of this project starts from scratch", or what the next install re-downloads.
        func cost(of subject: String) -> String {
            let downloads = names.intersection(ProjectsScanner.downloadedArtifacts).sorted()
            return (downloads.isEmpty
                ? "Next build of \(subject) starts from scratch"
                : "Next install re-downloads \(downloads.map(ProjectArtifacts.displayName(forFolder:)).joined(separator: ", "))")
                + (names.contains(".playwright-cli") ? "; old Playwright session logs and screenshots are gone" : "")
        }
    }
}
