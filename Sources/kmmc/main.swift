import CleanerCore
import Foundation

// Read-only companion CLI: shows what Vibe Clean would find. It never deletes anything.

let home = FileManager.default.homeDirectoryForCurrentUser
let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "scan"

func printDisk() {
    guard let disk = try? DiskSpace.read() else { return print("Couldn't read disk space") }
    print("Free: \(ByteFormat.short(disk.available)) of \(ByteFormat.short(disk.total)) (\(Int(disk.usedFraction * 100))% used)")
}

func locations() -> [URL] {
    let settings = SettingsStore().load()
    if settings.hasDiscoveredProjects {
        return settings.projectLocations.map { URL(fileURLWithPath: $0) }
    }
    return ProjectDiscovery.discoverLocations(home: home)
}

switch command {
case "disk":
    printDisk()

case "discover":
    let start = Date()
    let found = ProjectDiscovery.discoverLocations(home: home)
    print("Project locations (\(String(format: "%.1f", Date().timeIntervalSince(start)))s):")
    for location in found {
        let projects = ProjectDiscovery.projects(inLocations: [location])
        print("  \(PathFormat.abbreviated(location))  (\(projects.count) projects)")
    }

case "scan":
    printDisk()
    let context = ScanContext(
        home: home,
        projectLocations: locations(),
        largeFileMinimumSize: SettingsStore().load().largeFileThresholdBytes,
        temporaryDirectory: TemporaryFolder.user
    )
    print("Project locations: \(context.projectLocations.map { PathFormat.abbreviated($0) }.joined(separator: ", "))\n")
    let start = Date()
    var firstSeen: [String: TimeInterval] = [:]
    var lastSnapshot: ScanSnapshot?
    var reportedTenSeconds = false
    for await snapshot in ScanEngine.run(context: context) {
        let elapsed = Date().timeIntervalSince(start)
        for category in snapshot.categories where firstSeen[category.id] == nil {
            firstSeen[category.id] = elapsed
        }
        if elapsed > 10, !reportedTenSeconds {
            reportedTenSeconds = true
            print("After 10s: \(snapshot.categories.flatMap(\.items).count) items shown, \(snapshot.pending) still measuring")
        }
        lastSnapshot = snapshot
    }
    print(String(format: "Scan finished in %.1fs\n", Date().timeIntervalSince(start)))
    var totals: [Safety: Int64] = [:]
    for category in lastSnapshot?.categories ?? [] {
        let shown = String(format: "first shown after %.1fs", firstSeen[category.id] ?? 0)
        print("== \(category.title): \(ByteFormat.standard(category.totalSize)) (\(category.items.count) items, \(shown))")
        for item in category.items {
            totals[item.safety, default: 0] += item.size
            let size = ByteFormat.standard(item.size).padding(toLength: 10, withPad: " ", startingAt: 0)
            let badge = switch item.safety {
            case .safe: ""
            case .review: "[review] "
            case .personal: "[to trash] "
            }
            print("   \(size) \(badge)\(item.title)\(item.detail.map { " — \($0)" } ?? "")")
            for kept in item.skipped {
                print("              kept \(kept.url.lastPathComponent)/ (\(kept.reason))")
            }
            if item.safety == .review, let cost = item.cost {
                print("              ↳ \(item.costLevel?.label ?? "No cost"): \(cost)")
                if let reason = item.reason { print("                \(reason)") }
            }
        }
        print()
    }
    print("Safe: \(ByteFormat.standard(totals[.safe] ?? 0)) · Review: \(ByteFormat.standard(totals[.review] ?? 0))")

case "history":
    let history = HistoryStore().load()
    print("\(history.samples.count) free-space samples, \(history.scans.count) scan records")
    if let first = history.samples.first, let last = history.samples.last {
        print("From \(first.date.formatted()) (\(ByteFormat.short(first.available)) free) to \(last.date.formatted()) (\(ByteFormat.short(last.available)) free)")
    }
    if let trend = history.trend() {
        let days = trend.daysUntilFull.map { String(format: ", full in ~%.0f days", $0) } ?? ""
        print("Trend: \(ByteFormat.short(Int64(trend.bytesPerDay))) per day\(days)")
    } else {
        print("Trend: not enough history yet (needs 12 hours)")
    }

case "projects":
    // What the app knows about each project before any model is involved.
    for project in ProjectDiscovery.projects(inLocations: locations()) {
        let profile = ProjectProfiler.profile(of: project)
        print("\(profile.name)  [\(profile.stack ?? "unknown stack")]  \(profile.activity() ?? "no git history")")
        print("   \(profile.wantsModelSummary ? "[model] " : "")\(profile.plainBlurb ?? "—")")
        if arguments.contains("--prompts") { print("<<<\n\(profile.prompt)\n>>>") }
    }

case "worktrees":
    // Every linked worktree, whether everything in it is merged, and what the app offers for it.
    // `kmmc worktrees <text>` only checks worktrees whose path contains the text.
    let scanner = WorktreesScanner()
    let openFiles = OpenFiles.current()
    let filter = arguments.dropFirst().first
    let entries = GitWorktrees.find(in: ProjectDiscovery.projects(inLocations: locations()), home: home)
        .filter { entry in filter.map { entry.path.path.contains($0) } ?? true }
    for (gitDir, group) in Dictionary(grouping: entries, by: \.gitDir).sorted(by: { $0.key.path < $1.key.path }) {
        print("== \(PathFormat.abbreviated(gitDir)) (\(group.count == 1 ? "1 worktree" : "\(group.count) worktrees"))")
        for entry in group.sorted(by: { $0.path.path < $1.path.path }) {
            guard (try? PathGuard.validate(entry.path, home: home)) != nil else {
                print("   \(PathFormat.abbreviated(entry.path)): outside your home folder, not offered")
                continue
            }
            let start = Date()
            guard let info = GitWorktrees.inspect(entry) else {
                print("   \(PathFormat.abbreviated(entry.path)): git couldn't read it")
                continue
            }
            let state = info.isMerged ? "merged into \(info.base ?? "?") (\(info.merge.map { "\($0)" } ?? ""))" : "kept: \(info.keptSummary)"
            let openBy = openFiles?.processes(using: entry.path) ?? []
            let offer = scanner.item(for: info, openBy: openBy).map { item in
                let what = item.action.removesWorktree ? "remove worktree" : "build folders"
                return "\(what) \(ByteFormat.standard(item.size))\(item.safety == .review ? " [review]" : "")"
            } ?? "nothing to clean"
            print("   \(info.name)  \(state)  → \(offer)")
            print("      \(PathFormat.abbreviated(entry.path))  (checked in \(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
            if !openBy.isEmpty { print("      open in \(openBy.joined(separator: ", "))") }
            if let own = info.ownIgnoredFiles, !own.isEmpty {
                print("      \(own.count) ignored files only it has: \(own.prefix(3).joined(separator: ", "))\(own.count > 3 ? ", …" : "")")
            } else if info.isMerged, info.ownIgnoredFiles == nil {
                print("      ignored files couldn't be compared with the main checkout")
            }
        }
        print()
    }

case "digest":
    // The weekly summary as the app computes it. --sample uses a made-up week, for when history is short.
    let history: SpaceHistory
    var categories: [CleanupCategory] = []
    if arguments.contains("--sample") {
        (history, categories) = sampleWeek()
    } else {
        history = HistoryStore().load()
        let context = ScanContext(
            home: home, projectLocations: locations(), largeFileMinimumSize: SettingsStore().load().largeFileThresholdBytes,
            temporaryDirectory: TemporaryFolder.user
        )
        for await snapshot in ScanEngine.run(context: context) { categories = snapshot.categories }
    }
    let now = arguments.contains("--sample") ? history.samples.last?.date ?? Date() : Date()
    guard let facts = Digest.facts(history: history, categories: categories, now: now) else {
        let hours = history.samples.first.map { Int(Date().timeIntervalSince($0.date) / 3600) } ?? 0
        print("Not enough history yet: \(hours) hours of samples, the summary needs 2 days.")
        break
    }
    let summary = Digest.plainSummary(facts)
    print("\(summary.headline)\n\(summary.body)")
    if let grower = facts.biggestGrower {
        print("Shortcut: Select \(grower.title) (+\(ByteFormat.short(grower.bytes)))")
    }

default:
    print("usage: kmmc [scan|disk|discover|history|projects|worktrees [text]|digest [--sample]]")
}

/// A made-up week: losing ~1.3 GB a day, one 20 GB cleanup, Xcode build data and downloads growing.
func sampleWeek() -> (SpaceHistory, [CleanupCategory]) {
    let gb: Int64 = 1_000_000_000
    let start = Date().addingTimeInterval(-7 * 86_400)
    var history = SpaceHistory()
    var available = 41.0
    for hour in stride(from: 0.0, through: 168.0, by: 6.0) {
        if hour == 72 { available += 20 }
        history.record(SpaceSample(date: start.addingTimeInterval(hour * 3600), available: Int64(available * 1e9), total: 494 * gb))
        available -= 1.3 / 4
    }
    history.record(scan: ScanRecord(
        date: start,
        categorySizes: ["xcode": 40_300_000_000, "files": 1 * gb],
        itemSizes: ["dd": 10 * gb, "rest": 30_300_000_000]
    ))
    func item(_ id: String, _ title: String, _ size: Int64) -> CleanupItem {
        CleanupItem(id: id, title: title, size: size, safety: .safe, action: .removePaths([]))
    }
    return (history, [
        CleanupCategory(id: "xcode", title: "Xcode and simulators", symbol: "", items: [
            item("dd", "Acme build data", 15_800_000_000), item("rest", "Other", 30_300_000_000),
        ]),
        CleanupCategory(id: "files", title: "Large files and downloads", symbol: "", items: [item("apk", "app.apk", 2_200_000_000)]),
    ])
}
