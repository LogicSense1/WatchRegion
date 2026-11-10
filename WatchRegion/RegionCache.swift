// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

struct SalesRegion: Equatable, Sendable {
    let regionCode: String
    let salesSuffix: String

    static let unitedStates = SalesRegion(regionCode: "US", salesSuffix: "LL/A")

    var label: String { "\(regionCode) / \(salesSuffix)" }

    static func custom(regionCode: String, salesSuffix: String) -> SalesRegion? {
        let code = regionCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let suffix = salesSuffix.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false)
        func valid(_ part: Substring) -> Bool {
            (1...8).contains(part.utf8.count) && part.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
        }
        guard valid(code[...]), parts.count == 2, parts.allSatisfy(valid) else { return nil }
        return SalesRegion(regionCode: code, salesSuffix: suffix)
    }
}

struct WatchRegion: Sendable {
    let salesRegion: SalesRegion
    let originalRegion: SalesRegion?
    let bootTime: TimeInterval
    let changed: Bool

    var label: String { salesRegion.label }
}

enum RegionEdit: Sendable {
    case apply(SalesRegion), restore

    var restoresOriginal: Bool {
        if case .restore = self { return true }
        return false
    }
}

enum RegionCache {
    private static let cacheDirectory =
        "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"
    private static let regionCode = "h63QSdBCiT/z0WU6rdQv6Q"
    private static let regionSysconfig = "yK+xavymRGZ3xWc1tb8XDg"

    static func readOrUpdate(_ edit: RegionEdit?) throws -> WatchRegion {
        #if targetEnvironment(simulator)
        throw TransactionError("Use a physical Apple Watch to check its sales region.")
        #else
        let group = try validatedGroup()
        return try withRegionCache(group: group) { target, bytes in
            let live = try Cache(bytes)
            var original = try matchingBackup(for: live)
            let result: Cache
            switch edit {
            case .apply(let region) where region != live.region:
                if original == nil {
                    try saveBackup(live)
                    original = live
                }
                result = try live.settingRegion(region)
            case .restore:
                guard let original else { throw TransactionError("No original backup matches this cache.") }
                result = original.region == live.region ? live : original
            default:
                result = live
            }
            if result.bytes != live.bytes {
                try writeInPlace(before: live.bytes, after: result.bytes, at: target)
            }
            var boot = timeval()
            var size = MemoryLayout<timeval>.size
            let bootTime = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0
                ? TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000 : 0
            return WatchRegion(salesRegion: result.region, originalRegion: original?.region,
                               bootTime: bootTime, changed: result.bytes != live.bytes)
        }
        #endif
    }

    private static func validatedGroup() throws -> String {
        let files = FileManager.default
        guard let group = Bundle.main.object(forInfoDictionaryKey: "WatchRegionAppGroup") as? String,
              let root = files.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw TransactionError("App Group unavailable. Check the signed entitlement and profile.")
        }
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let isEmptyDirectory: Bool
        do {
            try files.createDirectory(at: caches, withIntermediateDirectories: true)
            let values = try caches.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            isEmptyDirectory = try values.isDirectory == true && values.isSymbolicLink == false
                && files.contentsOfDirectory(atPath: caches.path).isEmpty
        } catch {
            throw TransactionError("App Group preflight failed: \(error.localizedDescription)")
        }
        guard isEmptyDirectory else {
            throw TransactionError("Use a dedicated App Group with an empty Caches directory.")
        }
        return group
    }

    private static func matchingBackup(for live: Cache) throws -> Cache? {
        var fallback: Cache?
        for baseline in [false, true] {
            let url = try backupURL(restartBaseline: baseline)
            guard let bytes = try? Data(contentsOf: url), let backup = try? Cache(bytes),
                  live.matchesIgnoringRegion(backup) else { continue }
            if live.bytes == backup.bytes || (try? backup.settingRegion(live.region).bytes) == live.bytes {
                return backup
            }
            if fallback == nil { fallback = backup }
        }
        return fallback
    }

    private static func saveBackup(_ live: Cache) throws {
        let url = try backupURL(restartBaseline: false)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw TransactionError("The existing backup differs from this cache. Kept the original.")
        }
        try live.bytes.write(to: url, options: .withoutOverwriting)
        guard try Data(contentsOf: url) == live.bytes else {
            throw TransactionError("Could not verify the original backup.")
        }
    }

    private static func backupURL(restartBaseline: Bool) throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(restartBaseline ? "MobileGestalt-post-restart.plist" : "MobileGestalt-original.plist")
    }

    private static func withRegionCache<T>(group: String, _ body: (URL, Data) throws -> T) throws -> T {
        let directory = cacheDirectory
        let target = URL(fileURLWithPath: directory).appendingPathComponent("com.apple.MobileGestalt.plist")
        let token = worse_query(directory, group, false, false)
        guard token >= 0 else { throw TransactionError("Directory token failed (\(token)).") }
        defer { worse_query_release(token) }
        return try body(target, Data(contentsOf: target))
    }

    private static func writeInPlace(before: Data, after: Data, at target: URL) throws {
        let fd = open(target.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw TransactionError("In-place open failed (errno \(errno)).") }
        defer { close(fd) }
        var originalInfo = stat()
        guard fstat(fd, &originalInfo) == 0, (originalInfo.st_mode & S_IFMT) == S_IFREG else {
            throw TransactionError("Open cache is not a regular file.")
        }
        func sameInode() -> Bool {
            var liveInfo = stat()
            return lstat(target.path, &liveInfo) == 0 && liveInfo.st_dev == originalInfo.st_dev
                && liveInfo.st_ino == originalInfo.st_ino
        }
        func write(_ bytes: Data, range: Range<Int>) -> Bool {
            bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return range.isEmpty }
                var offset = range.lowerBound
                while offset < range.upperBound {
                    let count = pwrite(fd, base.advanced(by: offset), range.upperBound - offset, off_t(offset))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
        }
        guard sameInode(), try Data(contentsOf: target) == before else {
            throw TransactionError("Cache changed before the in-place write.")
        }
        let equalLengths = before.count == after.count
        var written: [Range<Int>] = []
        do {
            if equalLengths {
                var offset = 0
                while offset < after.count {
                    guard before[offset] != after[offset] else { offset += 1; continue }
                    let start = offset
                    repeat { offset += 1 } while offset < after.count && before[offset] != after[offset]
                    let range = start..<offset
                    written.append(range)
                    guard write(after, range: range) else {
                        throw TransactionError("In-place write failed (errno \(errno)).")
                    }
                }
            } else {
                guard write(after, range: after.indices), ftruncate(fd, off_t(after.count)) == 0 else {
                    throw TransactionError("In-place resize failed (errno \(errno)).")
                }
            }
            guard fsync(fd) == 0, sameInode(), try Data(contentsOf: target) == after else {
                throw TransactionError("Sync or in-place readback failed.")
            }
        } catch {
            guard sameInode() else { throw TransactionError("Cache inode changed; original backup retained.") }
            let rolledBack = equalLengths
                ? written.map { write(before, range: $0) }.allSatisfy { $0 }
                : write(before, range: before.indices) && ftruncate(fd, off_t(before.count)) == 0
            guard rolledBack, fsync(fd) == 0, (try? Data(contentsOf: target)) == before else {
                throw TransactionError("In-place rollback could not be verified; original backup retained.")
            }
            throw TransactionError("\(error.localizedDescription) Restored and verified input bytes.")
        }
    }

    private struct Cache {
        let bytes: Data
        let root: [String: Any]
        let fields: [String: Any]
        let region: SalesRegion

        init(_ bytes: Data) throws {
            var format = PropertyListSerialization.PropertyListFormat.binary
            let parsed = try PropertyListSerialization.propertyList(from: bytes, format: &format)
            guard format == .binary, let root = parsed as? [String: Any],
                  let fields = root["CacheExtra"] as? [String: Any],
                  let code = fields[regionCode] as? String, let suffix = fields[regionSysconfig] as? String else {
                throw TransactionError("The cache has no readable sales region.")
            }
            self.bytes = bytes
            self.root = root
            self.fields = fields
            self.region = SalesRegion(regionCode: code, salesSuffix: suffix)
        }

        func matchesIgnoringRegion(_ other: Cache) -> Bool {
            (root(setting: other.region) as NSDictionary).isEqual(to: other.root)
        }

        private func root(setting region: SalesRegion) -> [String: Any] {
            var expected = root
            var fields = fields
            fields[regionCode] = region.regionCode
            fields[regionSysconfig] = region.salesSuffix
            expected["CacheExtra"] = fields
            return expected
        }

        func settingRegion(_ region: SalesRegion) throws -> Cache {
            let expected = root(setting: region)
            if let bytes = patchStrings(for: region), let patched = try? Cache(bytes),
               (patched.root as NSDictionary).isEqual(to: expected) {
                return patched
            }
            let bytes = try PropertyListSerialization.data(fromPropertyList: expected, format: .binary, options: 0)
            let patched = try Cache(bytes)
            guard (patched.root as NSDictionary).isEqual(to: expected) else {
                throw TransactionError("Patched cache changes more than the two region values.")
            }
            return patched
        }

        private func patchStrings(for target: SalesRegion) -> Data? {
            var patched = bytes
            for (from, to) in [(region.regionCode, target.regionCode), (region.salesSuffix, target.salesSuffix)] where from != to {
                guard from.utf8.count == to.utf8.count, (1...14).contains(from.utf8.count),
                      from.utf8.allSatisfy({ $0 < 128 }), to.utf8.allSatisfy({ $0 < 128 }) else { return nil }
                let marker = UInt8(0x50 + from.utf8.count)
                let source = Data([marker] + Array(from.utf8))
                guard let range = bytes.range(of: source),
                      bytes.range(of: source, in: range.upperBound..<bytes.endIndex) == nil else { return nil }
                patched.replaceSubrange(range, with: [marker] + Array(to.utf8))
            }
            return patched
        }
    }

    private struct TransactionError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }
}
