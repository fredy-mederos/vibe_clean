import Foundation

/// Leftovers in your own temp folder (`$TMPDIR`, `/var/folders/…/T`): render bundles, recordings and export
/// folders that the tools that made them never delete. Recent ones are left out because something may still
/// be using them.
public struct TempFilesScanner: CleanupScanner {
    public let categoryID = "temp"
    public let title = "Temporary files"
    public let symbol = "clock.arrow.circlepath"

    /// Other temporary files and folders are listed from this size.
    public var otherMinimumSize: Int64

    public init(otherMinimumSize: Int64 = 100_000_000) {
        self.otherMinimumSize = otherMinimumSize
    }

    /// Leftovers changed more recently than this are left out: what made them may still be using them.
    static let inUseWithin: TimeInterval = 3600
    /// Temporary files nothing recognizes are only listed when nothing changed them for this long.
    static let otherUntouchedFor: TimeInterval = 3 * 86_400

    /// Leftovers of a tool we know, recognized by name.
    struct Leftover: Sendable {
        var id: String
        var title: String
        /// "bundle" in "30 bundles in the temp folder".
        var noun: String
        var matches: @Sendable (String) -> Bool
        var reason: String
        var cost: String
        var costLevel: CostLevel?
        var afterCleaning: String
        var blockers: [Blocker]
    }

    static let leftovers: [Leftover] = [
        Leftover(
            id: "remotion",
            title: "Remotion render bundles",
            noun: "folder",
            matches: { $0.hasPrefix("remotion-webpack-bundle-") || ($0.hasPrefix("remotion-v") && $0.contains("-assets")) },
            reason: "Copies of a Remotion project, public/ folder included, that bundle() makes for every render "
                + "and never deletes, and assets of renders that didn't finish.",
            cost: "Nothing: the next render bundles the project again",
            costLevel: nil,
            afterCleaning: "To stop them piling up, delete the folder bundle() returns once the render is done, "
                + "and pass symlinkPublicDir: true so public/ isn't copied each time.",
            blockers: [.remotion]
        ),
        Leftover(
            id: "instruments",
            title: "Instruments recordings",
            noun: "recording",
            matches: { $0.hasPrefix("instruments") && $0.hasSuffix(".ktrace") },
            reason: "Raw recordings Instruments left behind. A trace you saved has its own copy in the .trace file.",
            cost: "Recordings you never saved can't be opened again",
            costLevel: .loseOption,
            afterCleaning: "Saved .trace files aren't affected.",
            blockers: [.instruments]
        ),
        Leftover(
            id: "xcode-export",
            title: "Xcode export leftovers",
            noun: "folder",
            matches: { $0.hasPrefix("XcodeDistPipeline.") },
            reason: "Working folders Xcode leaves behind when it exports or uploads an archive.",
            cost: "Nothing: your archives and exported apps aren't touched",
            costLevel: nil,
            afterCleaning: "Xcode makes a new one the next time you distribute an archive.",
            blockers: [.xcode]
        ),
    ]

    struct Entry: Sendable {
        var url: URL
        var isDirectory: Bool
        var modified: Date?
        var name: String { url.lastPathComponent }
    }

    public func probes(in context: ScanContext) -> [ItemProbe] {
        guard let temp = context.temporaryDirectory else { return [] }
        let entries = Self.entries(of: temp)
        var probes = Self.leftovers.map { leftover in
            ItemProbe.one { Self.item(for: leftover, entries: entries.filter { leftover.matches($0.name) }) }
        }
        // Apple's own services keep their temporary files here while they run.
        let others = entries.filter { entry in
            !entry.name.hasPrefix("com.apple.") && !Self.leftovers.contains { $0.matches(entry.name) }
        }
        probes.append(ItemProbe { [otherMinimumSize] in
            others.compactMap { Self.otherItem(for: $0, minimumSize: otherMinimumSize) }
        })
        return probes
    }

    /// Top-level files and folders, not hidden ones or links.
    static func entries(of temp: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { return nil }
            return Entry(url: url, isDirectory: values.isDirectory == true, modified: values.contentModificationDate)
        }
        .sorted { $0.name < $1.name }
    }

    static func item(for leftover: Leftover, entries: [Entry], now: Date = Date()) -> CleanupItem? {
        let idle = entries.filter { entry in
            entry.modified.map { now.timeIntervalSince($0) >= inUseWithin } ?? true
        }
        var item = CleanupItem.folders(
            id: "temp:\(leftover.id)",
            title: leftover.title,
            detail: "\(ProjectFacts.count(idle.count, leftover.noun)) in the temp folder",
            urls: idle.map(\.url),
            safety: .safe,
            reason: leftover.reason,
            cost: leftover.cost,
            costLevel: leftover.costLevel,
            afterCleaning: leftover.afterCleaning,
            blockers: leftover.blockers,
            lastUsed: idle.compactMap(\.modified).max()
        )
        item?.dateKind = .modified
        return item
    }

    static func otherItem(for entry: Entry, minimumSize: Int64, now: Date = Date()) -> CleanupItem? {
        guard let modified = entry.modified, now.timeIntervalSince(modified) >= otherUntouchedFor else { return nil }
        let size = DirectorySize.reclaimableSize(of: entry.url)
        guard size >= minimumSize else { return nil }
        return CleanupItem(
            id: "temp.other:\(entry.url.path)",
            title: entry.name,
            detail: "Temporary \(entry.isDirectory ? "folder" : "file")",
            size: size,
            safety: .review,
            action: .removePaths([entry.url]),
            reason: "Left in the temp folder by an app or tool, and nothing changed it for 3 days or more. "
                + "Check what made it before you remove it.",
            cost: "Removed for good, and whatever made it may still expect it",
            costLevel: .dataLoss,
            afterCleaning: "Temporary files skip the Trash.",
            revealURL: entry.url,
            lastUsed: modified,
            dateKind: .modified
        )
    }
}
