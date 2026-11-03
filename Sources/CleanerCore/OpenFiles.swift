import Foundation

/// What your processes have open right now, working folders included, from one `lsof` pass (a fraction of a second).
/// Used to tell that a worktree is open in a terminal, a coding session or an editor.
public struct OpenFiles: Sendable {
    struct OpenPath: Sendable {
        var path: String
        var command: String
    }

    var open: [OpenPath]

    /// Servers that keep the folder they were started from as their working folder for as long as they run (adb
    /// until you restart), without using it.
    static let backgroundServers: Set<String> = ["adb"]

    init(open: [OpenPath]) {
        self.open = open
    }

    /// Nil when lsof can't run. This process and the commands it started (git, while scanning) don't count.
    public static func current() -> OpenFiles? {
        // -n -P: no host or port name lookups, which take seconds. +c 0: whole command names.
        guard let output = try? CommandRunner.run(
            "/usr/sbin/lsof", ["-n", "-P", "-w", "+c", "0", "-u", String(getuid()), "-F", "pcRn"], timeout: 20
        ), !output.stdout.isEmpty else { return nil }
        return parse(output.stdout, excludingDescendantsOf: getpid())
    }

    /// Parses `lsof -F pcRn`: a `p` line per process with its `c` command and `R` parent, then an `n` line per file.
    static func parse(_ output: String, excludingDescendantsOf ancestor: Int32) -> OpenFiles {
        var parents: [Int32: Int32] = [:]
        var commands: [Int32: String] = [:]
        var paths: [(pid: Int32, path: String)] = []
        var pid: Int32 = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int32(value) ?? 0
            case "c": commands[pid] = value
            case "R": parents[pid] = Int32(value)
            case "n" where value.hasPrefix("/"): paths.append((pid, value))
            default: continue
            }
        }
        func isOurs(_ pid: Int32) -> Bool {
            var current = pid
            for _ in 0..<64 {
                if current == ancestor { return true }
                guard let parent = parents[current], parent > 1 else { return false }
                current = parent
            }
            return false
        }
        return OpenFiles(open: paths.compactMap { pid, path in
            let command = commands[pid] ?? "a process"
            return isOurs(pid) || backgroundServers.contains(command) ? nil : OpenPath(path: path, command: command)
        })
    }

    /// The processes, by name, that have `folder` or something inside it open.
    public func processes(using folder: URL) -> [String] {
        let prefixes = Set([folder.standardizedFileURL.path, FileInfo.realPath(folder)].compactMap { $0 })
        let names = open.filter { entry in
            prefixes.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
        }.map(\.command)
        return Set(names).sorted()
    }
}
