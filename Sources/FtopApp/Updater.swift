import AppKit
import CryptoKit
import FtopCore
import os

/// Looks for a newer release and replaces the installed app with it.
///
/// An app built from a checkout instead builds itself again from that checkout: its
/// releases are Apple Silicon only, so there is no archive for it to download.
///
/// Only the app bundle the panel runs from is replaced. The setuid helper that
/// `sudo ftop grant` installed is outside the bundle and is never touched, so an
/// update cannot change what runs as root.
@MainActor
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(AppVersion)
        /// A checkout that is behind the branch it follows, with the subject of the newest commit.
        case sourceAvailable(String)
        case installing(AppVersion)
        case rebuilding
        case failed(String)
    }

    /// The checkout this app was built from; nil when it came from a release archive.
    struct SourceBuild: Equatable {
        var root: URL
        /// The commit the installed app was built from, when the bundle names one.
        var commit: String?
    }

    private(set) var state = State.idle {
        didSet { if state != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?
    var mode = UpdateMode.install
    /// Called just before the app quits to restart into the new version.
    var willRelaunch: (() -> Void)?

    private var found: ReleaseInfo?
    private var foundSource: String?
    private var busy = false
    private let log = Logger(subsystem: "dev.ftop", category: "update")
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    /// The version of the running app; nil when it was not started from an app bundle.
    static let current: AppVersion? = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)

    /// Only an installed `Ftop.app` the user may write to can replace itself.
    static var canInstall: Bool {
        let bundle = Bundle.main.bundleURL
        return current != nil && bundle.pathExtension == "app" && Bundle.main.bundleIdentifier == "dev.ftop.app"
            && FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// The checkout a local build was made from, read from the bundle's own Info.plist.
    /// A release archive has neither key, so it stays on the download path.
    static let sourceBuild: SourceBuild? = {
        guard let info = Bundle.main.infoDictionary, let path = info["FtopSourceRoot"] as? String, path.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) else { return nil }
        return SourceBuild(root: root, commit: (info["FtopBuildCommit"] as? String)?.split(separator: "-").first.map(String.init))
    }()

    /// The last line the source build wrote, for the settings row while it runs.
    private(set) var progress: String?

    /// `git fetch` in the checkout. Nil when the app already holds what the branch has,
    /// else the subject of the newest commit it does not. Measured from the commit the
    /// app was built from, not from the checkout's HEAD: a build that failed has left the
    /// checkout ahead of the app, and that is still an update to make.
    private func fetchSource() async -> Result<String?, Failure> {
        guard let source = Self.sourceBuild else { return .failure(Failure("this app was not built from a checkout")) }
        do {
            // A fork's origin is the fork itself, so its upstream is the one that moves.
            _ = try await Self.run(Self.git, ["fetch", "--quiet", "upstream"], in: source.root)
            guard let built = source.commit else {
                // Nothing says what this copy holds, so it is built again from the checkout.
                let subject = try await Self.run(Self.git, ["log", "-1", "--format=%s", "FETCH_HEAD"], in: source.root)
                return .success(subject.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let ahead = try await Self.run(Self.git, ["rev-list", "--count", "\(built)..FETCH_HEAD"], in: source.root)
            guard (Int(ahead.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 else { return .success(nil) }
            // The checkout is merged by the build script, never by the panel, so this only reports.
            let subject = try await Self.run(Self.git, ["log", "-1", "--format=%s", "FETCH_HEAD"], in: source.root).trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(subject)
        } catch {
            return .failure(error as? Failure ?? Failure(error.localizedDescription))
        }
    }

    /// Runs the checkout's build script and restarts into what it installs. The script
    /// is `scripts/rebuild.sh`: it fetches, merges, builds for this machine's
    /// architecture, replaces the installed app, and relaunches it.
    func rebuildFromSource() async {
        guard !busy, let source = Self.sourceBuild else { return }
        busy = true
        defer { busy = false }
        state = .rebuilding
        progress = nil
        do {
            let script = source.root.appending(path: "scripts/rebuild.sh")
            guard FileManager.default.isExecutableFile(atPath: script.path) else {
                throw Failure("this checkout has no scripts/rebuild.sh; pull it, then build again")
            }
            _ = try await Self.run(
                script.path, [], in: source.root,
                extra: ["FTOP_REBUILD_TARGET": Bundle.main.bundleURL.path]
            ) { [weak self] line in
                guard !line.isEmpty else { return }
                self?.progress = line
                self?.onChange?()
            }
            progress = nil
            try relaunch(Bundle.main.bundleURL)
        } catch {
            progress = nil
            fail(error)
        }
    }

    private static let git = "/usr/bin/git"

    /// Runs a tool to completion, returning what it printed. `onLine` gets the last line
    /// of each read, which is what a long build is worth showing while it runs.
    private nonisolated static func run(
        _ tool: String, _ arguments: [String], in directory: URL, extra: [String: String] = [:],
        onLine: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        try await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tool)
            task.arguments = arguments
            task.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            // A GUI app starts without the shell's PATH, and the build script needs swift.
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
            environment.merge(extra) { _, added in added }
            task.environment = environment
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                Task { @MainActor in onLine(line) }
            }
            defer { pipe.fileHandleForReading.readabilityHandler = nil }
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            guard task.terminationStatus == 0 else {
                let reason = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "\(tool) failed with status \(task.terminationStatus)"
                throw Failure(reason)
            }
            return output
        }.value
    }

    /// The daily check: does nothing when updates are off or the last check is recent.
    func checkIfDue() {
        guard mode != .off, Self.current != nil else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= Self.checkInterval else { return }
        Task { await check(install: mode == .install) }
    }

    /// Looks for a newer version now, where this copy came from: the checkout it was
    /// built from, or the release server. `install` also installs what it finds.
    func check(install: Bool) async {
        if Self.sourceBuild != nil { await checkSource() } else { await checkRelease(install: install) }
    }

    /// Asks the checkout's origin whether the branch has moved. The setting decides
    /// whether a newer checkout is rebuilt at once or only offered.
    func checkSource() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        state = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        switch await fetchSource() {
        case .failure(let error): fail(error)
        case .success(let subject?):
            foundSource = subject
            state = .sourceAvailable(subject)
            // Only a newer checkout is rebuilt on its own, and only when the setting says so.
            if mode == .install {
                busy = false
                await rebuildFromSource()
            }
        case .success(nil):
            foundSource = nil
            state = .upToDate
        }
    }

    /// Rebuilds and installs the checkout the last check found newer.
    func rebuildFound() {
        guard foundSource != nil, !busy else { return }
        Task { await rebuildFromSource() }
    }

    /// Asks the release server now. `install` also installs what it finds.
    func checkRelease(install: Bool) async {
        guard !busy, let current = Self.current else { return }
        busy = true
        defer { busy = false }
        state = .checking
        do {
            var request = URLRequest(url: UpdateFeed.latest, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await Self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure("the release server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard let release = UpdateFeed.release(from: data) else { throw Failure("the latest release has no archive ftop can install") }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            guard release.version > current else {
                found = nil
                state = .upToDate
                return
            }
            found = release
            state = .available(release.version)
            if install, Self.canInstall { try await self.install(release) }
        } catch {
            fail(error)
        }
    }

    /// Installs the release the last check found.
    func installFound() {
        guard let found, !busy, Self.canInstall else { return }
        Task {
            busy = true
            defer { busy = false }
            do { try await install(found) } catch { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        let reason = (error as? Failure)?.reason ?? error.localizedDescription
        log.error("update failed: \(reason, privacy: .public)")
        state = .failed(reason)
    }

    private func install(_ release: ReleaseInfo) async throws {
        state = .installing(release.version)
        let manager = FileManager.default
        let target = Bundle.main.bundleURL
        // Next to the installed app, so the final swap stays on one volume.
        let work = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? manager.removeItem(at: work) }

        let (downloaded, response) = try await Self.session.download(from: release.archive)
        let archive = work.appending(path: "update.zip")
        try manager.moveItem(at: downloaded, to: archive)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("the download answered \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        if let expected = release.sha256 {
            let actual = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw Failure("the downloaded archive does not match the checksum of the release") }
        }

        let unpacked = work.appending(path: "unpacked")
        try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let app = unpacked.appending(path: "Ftop.app")
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
            info["CFBundleIdentifier"] as? String == "dev.ftop.app",
            (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == release.version
        else { throw Failure("the archive does not hold ftop \(release.version)") }
        // A copy signed with the Developer ID accepts only an update signed the same way;
        // an ad-hoc copy (0.2.5 and earlier) can still move to a signed release.
        var verify = ["--verify", "--deep", "--strict"]
        if (try? await Self.run("/usr/bin/codesign", verify + ["-R=" + UpdateFeed.signer, target.path])) != nil {
            verify.append("-R=" + UpdateFeed.signer)
        }
        try await Self.run("/usr/bin/codesign", verify + [app.path])

        _ = try manager.replaceItemAt(target, withItemAt: app)
        log.info("installed \(release.version.description, privacy: .public), restarting")
        try relaunch(target)
    }

    /// Starts the new copy once this one has gone; two panels never run together.
    private func relaunch(_ bundle: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open -n -g -a \"$1\"",
            String(ProcessInfo.processInfo.processIdentifier), bundle.path,
        ]
        try task.run()
        willRelaunch?()
        NSApp.terminate(nil)
    }

    private struct Failure: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// No cookies, no cache, nothing kept on disk.
    private static let session = URLSession(configuration: .ephemeral)

    private nonisolated static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tool)
            task.arguments = arguments
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw Failure("\(tool) failed with status \(task.terminationStatus)") }
        }.value
    }
}
