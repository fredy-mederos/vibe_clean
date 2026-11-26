import Foundation

/// A linked git worktree: an extra checkout of a repository made with `git worktree add`. Claude Code, Codex,
/// Cursor and Conductor make one per task, each with its own build outputs, so they add up quickly.
public struct WorktreeInfo: Sendable, Hashable {
    /// How everything committed in a worktree got into the base branch.
    public enum Merge: Sendable, Hashable {
        /// Its commit is in the base branch's history: merged, fast-forwarded, or nothing new was committed.
        case contained
        /// Every commit has a twin in the base branch with the same changes (rebased or cherry-picked).
        case rebased
        /// One commit in the base branch has all its changes together (squash merge).
        case squashed
        /// The base branch has the exact version of every file it changed.
        case sameFiles
    }

    public var path: URL
    /// The repository's git folder, shared by all its worktrees (usually the main checkout's `.git`).
    public var gitDir: URL
    /// The main checkout's folder name.
    public var repositoryName: String
    /// The app that made it, when its location says so ("Claude Code", "Codex"...).
    public var tool: String?
    public var head: String
    /// Short branch name; nil when HEAD is detached.
    public var branch: String?
    /// The branch it's compared with, like "main" or "origin/develop"; nil when the repository has none.
    public var base: String?
    /// How its commits got into `base`; nil when some aren't there.
    public var merge: Merge?
    /// Commits not in `base`, not counting merge commits.
    public var unmergedCommits = 0
    /// Files git shows as changed or untracked. Ignored files (build outputs) don't count.
    public var uncommitted: [String] = []
    public var isLocked = false
    public var hasSubmodules = false
    /// When it was last worked in: commits and checkouts, or editing a file that's still uncommitted.
    public var lastActivity: Date?
    /// Files git ignores that only this worktree has, biggest first: not build outputs or editor state, and not
    /// copies of the main checkout's files. Removing the worktree deletes them. Only checked for merged worktrees;
    /// nil when they weren't or couldn't be.
    public var ownIgnoredFiles: [String]?

    /// Nothing in it is lost by removing it: its commits are in the base branch and nothing is uncommitted.
    public var isMerged: Bool { merge != nil && uncommitted.isEmpty }

    /// Merged, and `git worktree remove` takes it: it isn't locked and has no submodules (git refuses those).
    public var canBeRemoved: Bool { isMerged && !isLocked && !hasSubmodules }

    /// How it's listed: its folder name, or the branch when the app names folders after the repository
    /// (Codex: `<id>/<repository>`) or with random ids (Cursor).
    public var name: String {
        let folder = path.lastPathComponent
        if folder == repositoryName {
            return branch ?? "\(folder) (\(path.deletingLastPathComponent().lastPathComponent))"
        }
        return tool == "Cursor" ? branch ?? folder : folder
    }

    /// "Codex worktree of pokequiz, detached at 0c2d760".
    public var summary: String {
        let kind = tool.map { "\($0) worktree" } ?? "Worktree"
        let at = branch.map { "on \($0)" } ?? "detached at \(head.prefix(7))"
        return "\(kind) of \(repositoryName), \(at)"
    }

    /// What keeps it, for list rows: "2 uncommitted changes, 1 commit not in main".
    public var keptSummary: String {
        keptParts.map(\.short).joined(separator: ", ")
    }

    /// What keeps it, to finish "The worktree stays because …": "it has 1 uncommitted change (Notes.md)".
    public var keptBecause: String {
        let clauses = keptParts.map(\.long)
        guard let last = clauses.last else { return "it isn't merged" }
        return clauses.count == 1 ? last : clauses.dropLast().joined(separator: ", ") + " and " + last
    }

    private var keptParts: [(short: String, long: String)] {
        var parts: [(String, String)] = []
        if !uncommitted.isEmpty {
            let count = uncommitted.count == 1 ? "1 uncommitted change" : "\(uncommitted.count) uncommitted changes"
            let names = uncommitted.prefix(2).joined(separator: ", ") + (uncommitted.count > 2 ? " and \(uncommitted.count - 2) more" : "")
            parts.append((count, "it has \(count) (\(names))"))
        }
        if merge == nil {
            if let base {
                switch unmergedCommits {
                case 0: parts.append(("changes not in \(base)", "its changes aren't in \(base)"))
                case 1: parts.append(("1 commit not in \(base)", "1 commit isn't in \(base)"))
                default: parts.append(("\(unmergedCommits) commits not in \(base)", "\(unmergedCommits) commits aren't in \(base)"))
                }
            } else {
                parts.append(("no main branch", "the repository has no main branch to compare it with"))
            }
        }
        if isLocked { parts.append(("locked", "it's locked with git worktree lock")) }
        if hasSubmodules { parts.append(("has submodules", "it has submodules, which git worktree remove won't take")) }
        return parts
    }
}

/// Finds linked worktrees and checks, with git, whether everything in them is merged.
///
/// "Merged" means nothing would be lost by removing the worktree: every commit in it is in the repository's main
/// branch, and nothing is uncommitted. `git branch --merged` only sees merge commits and fast-forwards, so rebased
/// and squash-merged work (GitHub's other two merge buttons) is checked by content too.
public enum GitWorktrees {
    static let git = "/usr/bin/git"

    /// Folders in home where apps keep the worktrees they make. Claude Code (`.claude/worktrees`) and older
    /// Conductor versions (`.conductor`) keep them inside the repository, where the repository lists them.
    static let toolFolders: [(folder: String, tool: String)] = [
        (".codex/worktrees", "Codex"),
        (".cursor/worktrees", "Cursor"),
        ("conductor/workspaces", "Conductor"),
        (".t3/worktrees", "T3 Code"),
    ]

    /// Path fragments that tell which app made a worktree.
    static let toolMarkers: [(fragment: String, tool: String)] =
        [("/.claude/worktrees/", "Claude Code"), ("/.conductor/", "Conductor")] + toolFolders.map { ("/\($0.folder)/", $0.tool) }

    /// Branches with more commits or files than this aren't compared by content (it gets slow); they count as not merged.
    static let maxComparedCommits = 100
    static let maxComparedFiles = 1000

    /// A linked worktree registered in a repository's `worktrees` folder.
    public struct Entry: Sendable, Hashable {
        public var path: URL
        /// `<gitDir>/worktrees/<id>`: its HEAD, index, logs and lock.
        public var adminDir: URL
        public var gitDir: URL
    }

    // MARK: Finding worktrees

    /// The linked worktrees of the repositories that `folders` belong to, and of the repositories behind the
    /// worktrees apps keep in their own folders (so a repository outside your project folders still counts).
    public static func find(in folders: [URL], home: URL) -> [Entry] {
        var seen = Set<String>()
        var gitDirs: [URL] = []
        for folder in folders + toolWorktreeFolders(home: home) {
            guard let dotGit = dotGit(containing: folder, home: home),
                  let gitDir = commonGitDir(of: dotGit),
                  seen.insert(gitDir.path).inserted
            else { continue }
            gitDirs.append(gitDir)
        }
        return gitDirs.flatMap(linkedWorktrees(of:))
    }

    /// Whether `folder` is inside a linked worktree rather than a repository's main checkout.
    public static func isInLinkedWorktree(_ folder: URL, home: URL) -> Bool {
        guard let dotGit = dotGit(containing: folder, home: home), !FileInfo.isDirectory(dotGit),
              let gitDir = gitDirOfFile(dotGit)
        else { return false }
        return FileInfo.exists(gitDir.appendingPathComponent("commondir"))
    }

    /// Worktrees that apps keep in their own folders, a few levels down (`~/.codex/worktrees/<id>/<repository>`).
    static func toolWorktreeFolders(home: URL) -> [URL] {
        var found: [URL] = []
        for tool in toolFolders {
            var level = [home.appendingPathComponent(tool.folder)]
            for _ in 0..<3 where !level.isEmpty {
                var next: [URL] = []
                for child in level.flatMap(FileInfo.subdirectories(of:)) where !child.lastPathComponent.hasPrefix(".") {
                    if FileInfo.exists(child.appendingPathComponent(".git")) { found.append(child) } else { next.append(child) }
                }
                level = next
            }
        }
        return found
    }

    /// The `.git` folder or file of the checkout that holds `folder`, looking upwards but not past home.
    static func dotGit(containing folder: URL, home: URL) -> URL? {
        let homePath = home.standardizedFileURL.path
        var dir = folder.standardizedFileURL
        while dir.path.hasPrefix(homePath + "/") {
            let candidate = dir.appendingPathComponent(".git")
            if FileInfo.exists(candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The repository's shared git folder: a `.git` folder itself, or for a linked worktree's `.git` file, the
    /// folder its `commondir` names.
    static func commonGitDir(of dotGit: URL) -> URL? {
        if FileInfo.isDirectory(dotGit) { return dotGit.standardizedFileURL }
        guard let gitDir = gitDirOfFile(dotGit) else { return nil }
        if let common = firstLine(of: gitDir.appendingPathComponent("commondir")) {
            return resolve(common, relativeTo: gitDir)
        }
        // A submodule: its git folder is a repository of its own.
        return FileInfo.isDirectory(gitDir) ? gitDir : nil
    }

    /// The folder a `.git` file points to ("gitdir: …").
    static func gitDirOfFile(_ dotGit: URL) -> URL? {
        guard let line = firstLine(of: dotGit), line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return resolve(path, relativeTo: dotGit.deletingLastPathComponent())
    }

    /// The worktrees registered in a repository whose folders still exist.
    static func linkedWorktrees(of gitDir: URL) -> [Entry] {
        FileInfo.subdirectories(of: gitDir.appendingPathComponent("worktrees")).compactMap { admin in
            guard let line = firstLine(of: admin.appendingPathComponent("gitdir")) else { return nil }
            let dotGit = resolve(line, relativeTo: admin)
            // A worktree whose folder is gone (git calls it prunable) takes no space.
            guard FileInfo.exists(dotGit) else { return nil }
            return Entry(path: dotGit.deletingLastPathComponent(), adminDir: admin, gitDir: gitDir)
        }
    }

    static func repositoryName(of gitDir: URL) -> String {
        gitDir.lastPathComponent == ".git"
            ? gitDir.deletingLastPathComponent().lastPathComponent
            : gitDir.deletingPathExtension().lastPathComponent
    }

    static func tool(for path: URL) -> String? {
        let full = path.standardizedFileURL.path + "/"
        return toolMarkers.first { full.contains($0.fragment) }?.tool
    }

    private static func firstLine(of file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty
        else { return nil }
        return line
    }

    /// Git writes these paths absolute, or relative to the file's folder with `worktree.useRelativePaths`.
    private static func resolve(_ path: String, relativeTo folder: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : folder.appendingPathComponent(path).standardizedFileURL
    }

    // MARK: Checking with git

    /// Reads a worktree's state: HEAD, whether its commits are in the main branch, and what's uncommitted.
    /// Nil when git can't read it.
    public static func inspect(_ entry: Entry) -> WorktreeInfo? {
        guard let head = output(entry.path, ["rev-parse", "--verify", "-q", "HEAD"]),
              let uncommitted = uncommittedFiles(in: entry.path)
        else { return nil }
        var info = WorktreeInfo(
            path: entry.path,
            gitDir: entry.gitDir,
            repositoryName: repositoryName(of: entry.gitDir),
            tool: tool(for: entry.path),
            head: head,
            branch: firstLine(of: entry.adminDir.appendingPathComponent("HEAD"))
                .flatMap { $0.hasPrefix("ref: refs/heads/") ? String($0.dropFirst("ref: refs/heads/".count)) : nil }
        )
        info.uncommitted = uncommitted
        info.isLocked = FileInfo.exists(entry.adminDir.appendingPathComponent("locked"))
        info.hasSubmodules = FileInfo.exists(entry.path.appendingPathComponent(".gitmodules"))
        info.lastActivity = lastActivity(of: entry, uncommitted: uncommitted)

        let bases = baseBranches(in: entry.path)
        info.base = bases.first.map(shortName)
        for base in bases {
            if let merge = merge(of: head, into: base, in: entry.path) {
                info.merge = merge
                info.base = shortName(base)
                break
            }
        }
        if info.merge == nil, let base = bases.first {
            info.unmergedCommits = Int(output(entry.path, ["rev-list", "--count", "--no-merges", "\(base)..\(head)"]) ?? "") ?? 0
        }
        if info.isMerged {
            let mainCheckout = entry.gitDir.lastPathComponent == ".git" ? entry.gitDir.deletingLastPathComponent() : nil
            info.ownIgnoredFiles = ownIgnoredFiles(in: entry.path, mainCheckout: mainCheckout)
        }
        return info
    }

    /// When a worktree was last worked in: its last commit or checkout, the folder's own date (files added or
    /// removed at the top), or the latest edit to a file that's still uncommitted. Not the index: every
    /// `git status` from an editor or git app rewrites it, so it says when something last looked, not when you worked.
    static func lastActivity(of entry: Entry, uncommitted: [String]) -> Date? {
        let gitFiles = ["logs/HEAD", "HEAD"].map { entry.adminDir.appendingPathComponent($0) }
        // Untracked folders are listed as "folder/"; their own date is enough.
        let edited = uncommitted.prefix(200).map { entry.path.appendingPathComponent($0) }
        return (gitFiles + [entry.path] + edited).compactMap(FileInfo.modificationDate).max()
    }

    /// The repository's main branches as full ref names, best first: origin's default branch, then main, master,
    /// develop and trunk, each local and on origin. Work in any of them is kept for good.
    static func baseBranches(in worktree: URL) -> [String] {
        var names = ["main", "master", "develop", "trunk"]
        if let originHead = output(worktree, ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]),
           originHead.hasPrefix("refs/remotes/origin/") {
            let name = String(originHead.dropFirst("refs/remotes/origin/".count))
            names.removeAll { $0 == name }
            names.insert(name, at: 0)
        }
        let candidates = names.flatMap { ["refs/heads/\($0)", "refs/remotes/origin/\($0)"] }
        let existing = Set((output(worktree, ["for-each-ref", "--format=%(refname)"] + candidates) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init))
        return candidates.filter(existing.contains)
    }

    /// "refs/heads/main" → "main", "refs/remotes/origin/main" → "origin/main".
    static func shortName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    /// How everything committed at `head` got into `base`, or nil when something isn't there. History first, then
    /// content: the files it changed, then each commit's changes, then all of them together.
    static func merge(of head: String, into base: String, in worktree: URL) -> WorktreeInfo.Merge? {
        if run(worktree, ["merge-base", "--is-ancestor", head, base])?.status == 0 { return .contained }
        guard let forkPoint = output(worktree, ["merge-base", base, head]),
              let changed = run(worktree, ["diff", "--no-renames", "--name-only", "-z", forkPoint, head]), changed.status == 0
        else { return nil }
        // Renames count as a delete and an add, so both paths are compared.
        let paths = changed.stdout.split(separator: "\0").map(String.init)
        if paths.isEmpty { return .sameFiles }
        guard paths.count <= maxComparedFiles else { return nil }
        if run(worktree, ["diff", "--quiet", "--no-renames", "--no-ext-diff", "--no-textconv", base, head, "--"] + paths)?.status == 0 {
            return .sameFiles
        }

        let commits = (output(worktree, ["rev-list", "--no-merges", "\(base)..\(head)"]) ?? "").split(whereSeparator: \.isNewline).map(String.init)
        guard !commits.isEmpty, commits.count <= maxComparedCommits else { return nil }
        // Patch ids of the base's commits since the fork that touch the same files. Without context lines: after a
        // rebase the lines around a change often differ, which is why `git cherry` misses many rebased commits.
        let logPatches = ["log", "-p", "-U0", "--binary", "--no-merges", "--no-color", "--no-ext-diff", "--no-textconv", "--format=commit %H"]
        let baseIDs = Set(patchIDs(in: worktree, logPatches + ["--full-diff", "\(forkPoint)..\(base)", "--"] + paths).map(\.id))
        let own = Dictionary(patchIDs(in: worktree, logPatches + ["\(base)..\(head)"]).map { ($0.commit, $0.id) }) { first, _ in first }
        if commits.allSatisfy({ own[$0].map(baseIDs.contains) == true }) { return .rebased }
        let squashed = patchIDs(in: worktree, ["diff", "-U0", "--binary", "--no-color", "--no-ext-diff", "--no-textconv", forkPoint, head])
        if let id = squashed.first?.id, baseIDs.contains(id) { return .squashed }
        return nil
    }

    /// Paths git shows as modified, staged, deleted or untracked. Nil when git fails.
    static func uncommittedFiles(in worktree: URL) -> [String]? {
        guard let output = run(worktree, ["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none"], timeout: 60),
              output.status == 0
        else { return nil }
        // Entries are "XY path"; renames and copies are followed by the original path.
        var files: [String] = []
        var entries = output.stdout.split(separator: "\0")[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            files.append(String(entry.dropFirst(3)))
            if entry.prefix(2).contains(where: { $0 == "R" || $0 == "C" }) { _ = entries.popFirst() }
        }
        return files
    }

    // MARK: Ignored files only a worktree has

    /// Ignored folders that only hold build outputs, caches or editor state, wherever they are. Folders an artifact
    /// rule matches (`ProjectArtifacts`) count too.
    static let regeneratedFolderNames: Set<String> = [
        "build", ".gradle", ".kotlin", ".cxx", ".externalNativeBuild", "node_modules", ".next", ".nuxt", ".turbo",
        ".parcel-cache", ".svelte-kit", ".angular", ".dart_tool", "Pods", ".build", "DerivedData", ".venv", "venv",
        ".expo", "_build", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".idea", ".vscode",
        "xcuserdata", ".swiftpm",
    ]
    /// Lock files are only regenerated when git ignores them, which it does for these to be listed.
    static let regeneratedFileNames: Set<String> = [".DS_Store", "package-lock.json", "yarn.lock", "pnpm-lock.yaml"]
    /// More ignored files than this aren't compared one by one; the worktree counts as having files of its own.
    static let maxComparedIgnoredFiles = 20_000

    /// Files git ignores that only `worktree` has, biggest first: not in build output, cache or editor folders, and
    /// not the same file at the same place in `mainCheckout` (apps copy `.env` and the like into new worktrees).
    /// Links aren't counted: removing one loses no data. Nil when git can't list them or there are too many.
    static func ownIgnoredFiles(in worktree: URL, mainCheckout: URL?) -> [String]? {
        guard let listed = run(worktree, ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], timeout: 60),
              listed.status == 0
        else { return nil }
        let root = worktree.standardizedFileURL
        // Artifact folders as relative paths. Folders may come back as /private/var/… for /var/….
        let rootPaths = [root.path, FileInfo.realPath(root)].compactMap { $0 }
        let artifacts = Set(ProjectArtifacts.findArtifacts(in: root).compactMap { url -> String? in
            let path = url.standardizedFileURL.path
            return rootPaths.first { path.hasPrefix($0 + "/") }.map { String(path.dropFirst($0.count + 1)) }
        })
        func isRegenerated(folder relative: String) -> Bool {
            let parts = relative.split(separator: "/")
            return parts.indices.contains { index in
                regeneratedFolderNames.contains(String(parts[index])) || artifacts.contains(parts[...index].joined(separator: "/"))
            }
        }

        // Ignored files, and the files in ignored folders, outside build outputs and editor state. Git can list a
        // folder and folders inside it, so each file is kept once.
        var candidates: [String: Int64] = [:]
        for entry in listed.stdout.split(separator: "\0").map(String.init) {
            let isFolder = entry.hasSuffix("/")
            let relative = isFolder ? String(entry.dropLast()) : entry
            let name = (relative as NSString).lastPathComponent
            if isRegenerated(folder: isFolder ? relative : (relative as NSString).deletingLastPathComponent) { continue }
            let path = root.appendingPathComponent(relative).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            if attributes[.type] as? FileAttributeType == .typeRegular {
                if !regeneratedFileNames.contains(name) { candidates[relative] = (attributes[.size] as? NSNumber)?.int64Value ?? 0 }
                continue
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let walker = FileManager.default.enumerator(atPath: path)
            else { continue }
            while let sub = walker.nextObject() as? String {
                let inner = relative + "/" + sub
                let innerName = (sub as NSString).lastPathComponent
                switch walker.fileAttributes?[.type] as? FileAttributeType {
                case .typeDirectory?:
                    if regeneratedFolderNames.contains(innerName) || artifacts.contains(inner) { walker.skipDescendants() }
                case .typeRegular? where !regeneratedFileNames.contains(innerName):
                    candidates[inner] = (walker.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
                    if candidates.count > maxComparedIgnoredFiles { return nil }
                default:
                    continue
                }
            }
        }

        return candidates
            .filter { relative, size in
                let file = root.appendingPathComponent(relative)
                if isGeneratedLocalProperties(file) { return false }
                guard let mainCheckout else { return true }
                return !sameContents(file, mainCheckout.appendingPathComponent(relative), size: size)
            }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }

    /// Android Studio writes a local.properties with only where the SDK is into every checkout it opens. Other
    /// keys (signing, tokens) were added by hand.
    static func isGeneratedLocalProperties(_ file: URL) -> Bool {
        guard file.lastPathComponent == "local.properties",
              let text = try? String(contentsOf: file, encoding: .utf8)
        else { return false }
        return text.split(whereSeparator: \.isNewline).allSatisfy { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!")
                || ["sdk.dir", "ndk.dir", "cmake.dir"].contains { line.hasPrefix($0 + "=") }
        }
    }

    /// Whether `other` is a file with the same bytes as `file`. APFS clones that share all their data are, without
    /// reading either.
    static func sameContents(_ file: URL, _ other: URL, size: Int64) -> Bool {
        guard let values = try? other.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, Int64(values.fileSize ?? -1) == size
        else { return false }
        if let first = CloneSharing(path: file.path), let second = CloneSharing(path: other.path),
           first.cloneID != nil, first.cloneID == second.cloneID, first.privateSize == 0, second.privateSize == 0 {
            return true
        }
        return FileManager.default.contentsEqual(atPath: file.path, andPath: other.path)
    }

    // MARK: Removing

    /// Removes a worktree with `git worktree remove` if it's still on `head`. Git refuses when files changed or
    /// appeared since the scan; the branch stays. Returns why it failed, or nil.
    public static func remove(_ worktree: URL, gitDir: URL, head: String) -> String? {
        guard FileInfo.exists(worktree) else { return nil }
        guard output(worktree, ["rev-parse", "--verify", "-q", "HEAD"]) == head else {
            return "It has new commits since the last scan. Scan again to check it."
        }
        // From the main checkout, or from a bare repository itself.
        let repository = gitDir.lastPathComponent == ".git" ? gitDir.deletingLastPathComponent() : gitDir
        guard let result = try? CommandRunner.run(git, ["-C", repository.path, "worktree", "remove", worktree.path], timeout: 600) else {
            return "git didn't finish removing it."
        }
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "fatal: ", with: "")
            return message.isEmpty ? "git couldn't remove it (\(result.status))." : message
        }
        return nil
    }

    // MARK: Running git

    /// Read-only options: no index refresh or lock, no file monitor started, pathspecs taken literally.
    private static func options(_ worktree: URL) -> [String] {
        ["--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "log.showSignature=false",
         "-c", "core.quotePath=false", "-C", worktree.path]
    }

    private static func run(_ worktree: URL, _ arguments: [String], timeout: TimeInterval = 20) -> CommandRunner.Output? {
        try? CommandRunner.run(git, options(worktree) + arguments, timeout: timeout)
    }

    /// Trimmed output of a git command that succeeded.
    private static func output(_ worktree: URL, _ arguments: [String]) -> String? {
        guard let output = run(worktree, arguments), output.status == 0 else { return nil }
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// `git <arguments>` piped into `git patch-id` by a shell, so big diffs stream between the two.
    private static func patchIDs(in worktree: URL, _ arguments: [String]) -> [(id: String, commit: String)] {
        let script = #"git="$1"; shift; "$git" "$@" | "$git" patch-id --stable"#
        guard let output = try? CommandRunner.run("/bin/sh", ["-c", script, "sh", git] + options(worktree) + arguments, timeout: 60),
              output.status == 0
        else { return [] }
        return output.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ")
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
    }
}
