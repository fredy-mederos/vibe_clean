import Foundation

/// Conversations that AI coding tools save so you can resume them. Only old ones are offered, for review: they're
/// your history, but the tools don't need them to work. Their settings, memory and the desktop apps' data are
/// never touched.
public struct AIToolsScanner: CleanupScanner {
    public let categoryID = "ai"
    public let title = "AI coding tools"
    public let symbol = "sparkles"

    /// Conversations not changed for this long are offered.
    let olderThan: TimeInterval

    public init(olderThan: TimeInterval = 30 * 86_400) {
        self.olderThan = olderThan
    }

    public func probes(in context: ScanContext) -> [ItemProbe] {
        [
            .one { codexConversations(context) },
            .one { claudeCodeConversations(context) },
        ]
    }

    /// `~/.codex/sessions/<year>/<month>/<day>/rollout-….jsonl`, one file per conversation.
    func codexConversations(_ context: ScanContext, now: Date = Date()) -> CleanupItem? {
        let cutoff = now.addingTimeInterval(-olderThan)
        var files: [URL] = []
        var newest: Date?
        if let walker = FileManager.default.enumerator(
            at: context.path(".codex/sessions"), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) {
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate, modified < cutoff
                else { continue }
                files.append(file)
                newest = max(newest ?? modified, modified)
            }
        }
        return item(
            id: "ai.codex.conversations", title: "Codex conversations", count: files.count, urls: files, newest: newest,
            days: olderThan, resume: "codex resume", revealURL: context.path(".codex/sessions")
        )
    }

    /// `~/.claude/projects/<project>/<session>.jsonl`, with the `<session>/` folder of its subagents and tool
    /// output. Claude Code removes these itself after `cleanupPeriodDays` (30 by default), so only older ones are
    /// offered. The project's `memory/` and anything else stays.
    func claudeCodeConversations(_ context: ScanContext, now: Date = Date()) -> CleanupItem? {
        let keptDays = (FileInfo.json(at: context.path(".claude/settings.json"))?["cleanupPeriodDays"] as? Int).map(Double.init) ?? 0
        let days = max(olderThan, keptDays * 86_400)
        let cutoff = now.addingTimeInterval(-days)
        var urls: [URL] = []
        var count = 0
        var newest: Date?
        for project in FileInfo.subdirectories(of: context.path(".claude/projects")) {
            for name in FileInfo.childNames(of: project) where name.hasSuffix(".jsonl") {
                let transcript = project.appendingPathComponent(name)
                guard let modified = FileInfo.modificationDate(transcript), modified < cutoff else { continue }
                urls.append(transcript)
                count += 1
                newest = max(newest ?? modified, modified)
                let folder = transcript.deletingPathExtension()
                if FileInfo.isDirectory(folder), folder.lastPathComponent != "memory" { urls.append(folder) }
            }
        }
        return item(
            id: "ai.claude.conversations", title: "Claude Code conversations", count: count, urls: urls, newest: newest,
            days: days, resume: "claude --resume", revealURL: context.path(".claude/projects")
        )
    }

    private func item(
        id: String, title: String, count: Int, urls: [URL], newest: Date?, days: TimeInterval, resume: String, revealURL: URL
    ) -> CleanupItem? {
        let age = "\(Int(days / 86_400)) days"
        var item = CleanupItem.folders(
            id: id,
            title: title,
            detail: "\(ProjectFacts.count(count, "conversation")) older than \(age)",
            urls: urls,
            safety: .review,
            reason: "Conversations from more than \(age) ago, saved so you can pick them up again with \(resume). "
                + "The tool's settings and memory stay.",
            cost: "You can't resume or reread these conversations",
            costLevel: .dataLoss,
            afterCleaning: "New conversations are saved as before.",
            revealURL: revealURL,
            lastUsed: newest
        )
        item?.dateKind = .modified
        return item
    }
}
