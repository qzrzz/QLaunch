import Darwin

/// Filesystem metadata recorded as the application scanner walks its sources.
public struct ApplicationCatalogSnapshot: Sendable {
    private struct Stamp: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int

        static func read(_ path: String) -> Self? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return Self(
                device: info.st_dev,
                inode: info.st_ino,
                modificationSeconds: info.st_mtimespec.tv_sec,
                modificationNanoseconds: info.st_mtimespec.tv_nsec,
                changeSeconds: info.st_ctimespec.tv_sec,
                changeNanoseconds: info.st_ctimespec.tv_nsec
            )
        }
    }

    public let capturedAt = ContinuousClock.now
    private var stamps: [String: Stamp?] = [:]

    public init() {}

    public mutating func record(_ path: String) {
        guard stamps.index(forKey: path) == nil else { return }
        // Keep unavailable paths so the next check detects their appearance.
        stamps.updateValue(Stamp.read(path), forKey: path)
    }

    public func matchesDisk() -> Bool {
        stamps.allSatisfy { Stamp.read($0.key) == $0.value }
    }
}
