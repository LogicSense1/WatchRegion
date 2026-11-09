// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

struct WatchRegion: Sendable {
    let countryCode: String
    let salesCode: String
    let bootTime: TimeInterval
    let changed: Bool

    var label: String { "\(countryCode) / \(salesCode)" }
}

enum RegionEdit: Sendable {
    case apply, restore

    var restoresOriginal: Bool { self == .restore }
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
        return try withRegionCache(group: group) { target, live in
            var data = live
            if let edit {
                let original = try watchBackup(matching: live, restore: edit.restoresOriginal)
                let patched = try usPreset(from: original)
                let (before, after) = edit.restoresOriginal ? (patched, original) : (original, patched)
                if live != after {
                    try writeInPlace(before: before, after: after, at: target)
                    data = after
                }
            }

            let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard let fields = root?["CacheExtra"] as? [String: Any],
                  let code = fields[regionCode] as? String, let sales = fields[regionSysconfig] as? String else {
                throw TransactionError("The cache has no readable sales region.")
            }
            var boot = timeval()
            var size = MemoryLayout<timeval>.size
            let bootTime = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0
                ? TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000 : 0
            return WatchRegion(countryCode: code, salesCode: sales, bootTime: bootTime, changed: data != live)
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

    private static func watchBackup(matching live: Data, restore: Bool) throws -> Data {
        for baseline in [false, true] {
            let url = try backupURL(restartBaseline: baseline)
            guard let original = try? Data(contentsOf: url),
                  let patched = try? usPreset(from: original) else { continue }
            if live == original || live == patched { return original }
        }

        guard !restore else { throw TransactionError("No original backup matches this cache.") }
        _ = try usPreset(from: live)
        let url = try backupURL(restartBaseline: false)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw TransactionError("The existing backup differs from this cache. Kept the original.")
        }
        try live.write(to: url, options: .withoutOverwriting)
        guard try Data(contentsOf: url) == live else {
            throw TransactionError("Could not verify the original backup.")
        }
        return live
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
        guard before.count == after.count else { throw TransactionError("In-place write requires equal lengths.") }
        let offsets = before.indices.filter { before[$0] != after[$0] }
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
        func writeByte(_ value: UInt8, at offset: Int) -> Bool {
            var byte = value
            while true {
                let count = pwrite(fd, &byte, 1, off_t(offset))
                if count == 1 { return true }
                if count < 0 && errno == EINTR { continue }
                return false
            }
        }
        guard sameInode(), try Data(contentsOf: target) == before else {
            throw TransactionError("Cache changed before the in-place write.")
        }
        var written: [Int] = []
        do {
            for offset in offsets {
                guard writeByte(after[offset], at: offset) else {
                    throw TransactionError("In-place write failed (errno \(errno)).")
                }
                written.append(offset)
            }
            guard fsync(fd) == 0, sameInode(), try Data(contentsOf: target) == after else {
                throw TransactionError("Sync or in-place readback failed.")
            }
        } catch {
            guard sameInode() else { throw TransactionError("Cache inode changed; original backup retained.") }
            let rolledBack = written.map { writeByte(before[$0], at: $0) }.allSatisfy { $0 }
            guard rolledBack, fsync(fd) == 0, (try? Data(contentsOf: target)) == before else {
                throw TransactionError("In-place rollback could not be verified; original backup retained.")
            }
            throw TransactionError("\(error.localizedDescription) Restored and verified input bytes.")
        }
    }

    private static func usPreset(from original: Data) throws -> Data {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let parsed = try PropertyListSerialization.propertyList(from: original, format: &format)
        guard format == .binary, var expected = parsed as? [String: Any],
              var fields = expected["CacheExtra"] as? [String: Any],
              fields[regionCode] as? String == "CH", fields[regionSysconfig] as? String == "CH/B" else {
            throw TransactionError("Backup is not the expected CH / CH/B binary cache.")
        }
        var patched = original
        for (key, from, to) in [(regionCode, "CH", "US"), (regionSysconfig, "CH/B", "LL/A")] {
            let marker = UInt8(0x50 + from.utf8.count)
            let source = Data([marker] + Array(from.utf8))
            guard let range = patched.range(of: source),
                  patched.range(of: source, in: range.upperBound..<patched.endIndex) == nil else {
                throw TransactionError("Region string is not unique in the binary cache.")
            }
            patched.replaceSubrange(range, with: [marker] + Array(to.utf8))
            fields[key] = to
        }
        expected["CacheExtra"] = fields
        let check = try PropertyListSerialization.propertyList(from: patched, format: nil) as? NSDictionary
        guard check?.isEqual(to: expected) == true else {
            throw TransactionError("Patched cache changes more than the two expected values.")
        }
        return patched
    }

    private struct TransactionError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }
}
