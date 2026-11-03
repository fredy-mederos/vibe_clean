import Foundation

/// Fast on-disk size calculation using `fts` (the same walker `du` uses).
public enum DirectorySize {
    /// Bytes that deleting a file or folder tree frees. Hard links are counted once. Never follows symlinks
    /// and never crosses into another volume.
    ///
    /// Unlike `du`, data a file shares with an APFS clone outside the tree doesn't count: deleting a worktree's
    /// copy of a video cloned from the main checkout frees nothing. Full clones that are all inside count once.
    public static func reclaimableSize(of url: URL) -> Int64 {
        reclaimableSize(of: [url])
    }

    public static func reclaimableSize(of urls: [URL]) -> Int64 {
        let paths = urls.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return 0 }

        var cPaths: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) }
        cPaths.append(nil)
        defer { cPaths.forEach { free($0) } }

        guard let fts = fts_open(&cPaths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }

        var total: Int64 = 0
        var seenHardLinks = Set<HardLinkKey>()
        var cloneFamilies: [UInt64: CloneFamily] = [:]
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let stat = entry.pointee.fts_statp?.pointee else { continue }
                if info != FTS_D, stat.st_nlink > 1 {
                    let key = HardLinkKey(device: Int64(stat.st_dev), inode: UInt64(stat.st_ino))
                    if !seenHardLinks.insert(key).inserted { continue }
                }
                let blocks = Int64(stat.st_blocks) * 512
                guard info == FTS_F, blocks >= cloneCheckMinimum,
                      let sharing = CloneSharing(path: entry.pointee.fts_path), sharing.privateSize < blocks
                else {
                    total += blocks
                    continue
                }
                total += sharing.privateSize
                if let id = sharing.cloneID, let members = sharing.fullClones, members > 1 {
                    var family = cloneFamilies[id] ?? CloneFamily(members: Int(members))
                    family.seen += 1
                    family.shared = max(family.shared, blocks - sharing.privateSize)
                    cloneFamilies[id] = family
                }
            default:
                continue
            }
        }
        // Data only files inside share is freed with them, once.
        for family in cloneFamilies.values where family.seen >= family.members {
            total += family.shared
        }
        return total
    }

    /// Bytes that deleting this one file frees, not counting data it shares with clones.
    static func reclaimableBytes(ofFile path: UnsafePointer<CChar>, blocks: Int64) -> Int64 {
        guard blocks >= cloneCheckMinimum, let sharing = CloneSharing(path: path) else { return blocks }
        return min(sharing.privateSize, blocks)
    }

    /// Smaller files are counted whole: checking each one for clones would slow sizing down for little gain.
    static let cloneCheckMinimum: Int64 = 16 * 1024

    private struct HardLinkKey: Hashable {
        let device: Int64
        let inode: UInt64
    }

    private struct CloneFamily {
        /// Files with this data, from APFS.
        var members: Int
        /// How many of them are in the tree.
        var seen = 0
        var shared: Int64 = 0
    }
}

/// How much of a file's data it shares with APFS clones, from `getattrlist`. Nil where the volume doesn't say
/// (HFS+, network volumes), in which case the file counts whole.
struct CloneSharing {
    /// Bytes freed right away if this file alone is deleted.
    var privateSize: Int64
    /// The same for files that are full clones of each other.
    var cloneID: UInt64?
    /// How many files share all of this file's data, itself included.
    var fullClones: UInt32?

    init?(path: UnsafePointer<CChar>) {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        // With FSOPT_ATTR_CMN_EXTENDED, the fork attributes are the common extended ones.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
        // u_int32_t length, attribute_set_t (5 × u_int32_t), then the returned values in bit order.
        var buffer = (Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0))
        let size = MemoryLayout.size(ofValue: buffer)
        let status = withUnsafeMutableBytes(of: &buffer) { raw in
            getattrlist(path, &request, raw.baseAddress, size, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        let values: (Int64?, UInt64?, UInt32?) = withUnsafeBytes(of: &buffer) { raw in
            let returned = raw.loadUnaligned(fromByteOffset: 4 + 4 * 4, as: UInt32.self)
            var offset = 24
            func next<T>(_ bit: Int32, _ type: T.Type) -> T? {
                guard returned & UInt32(bit) != 0 else { return nil }
                defer { offset += MemoryLayout<T>.size }
                return raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            return (next(ATTR_CMNEXT_PRIVATESIZE, Int64.self), next(ATTR_CMNEXT_CLONEID, UInt64.self), next(ATTR_CMNEXT_CLONE_REFCNT, UInt32.self))
        }
        guard let privateSize = values.0 else { return nil }
        self.privateSize = max(privateSize, 0)
        cloneID = values.1
        fullClones = values.2
    }
}

enum FileInfo {
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Child folders (not files, not symlinks), including hidden ones.
    static func subdirectories(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else {
            return []
        }
        return children.filter { child in
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func childNames(of url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    /// The path with every link resolved, "/private/var/folders/…" for "/var/folders/…". Nil if it doesn't exist.
    /// Unlike `resolvingSymlinksInPath()`, which drops /private again.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func json(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

public enum TemporaryFolder {
    /// Your own temp folder, `/var/folders/…/T`, where `$TMPDIR` normally points. Tools that never clean up
    /// after themselves leave their files here.
    public static var user: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // Cleaning may remove what's inside, so never accept anything else.
        guard FileInfo.realPath(url)?.hasPrefix("/private/var/folders/") == true else { return nil }
        return url
    }

    /// `user`'s path as macOS gives it and with links resolved: its contents can come back as /private/var/….
    static let userPaths: [String] = user.map { [$0.standardizedFileURL.path, FileInfo.realPath($0)].compactMap { $0 } } ?? []
}

/// Numeric comparison of dotted version strings ("2026.1.10" > "2026.1.9", "8.13" > "8.9").
public enum Version {
    public static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix(while: \.isNumber)) ?? 0
        }
    }

    public static func isOrderedBefore(_ a: String, _ b: String) -> Bool {
        let lhs = components(a)
        let rhs = components(b)
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l < r }
        }
        return a < b
    }
}
