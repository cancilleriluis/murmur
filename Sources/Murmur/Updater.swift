import AppKit

/// Updates Murmur from the git checkout it was built from: pull `main`, then
/// run `build.sh --install`, which replaces the app and relaunches it.
///
/// The app is always built on this Mac (so it carries your own signing
/// identity and keeps its permissions), which is why updating means rebuilding
/// rather than downloading a binary. `build.sh` records the checkout's path in
/// Info.plist; a build made before that has no updater and needs one manual
/// `./build.sh --install`.
enum Updater {

    struct Status {
        let behind: Int          // commits on origin/main not in this build
        let summary: [String]    // their subject lines, newest first
    }

    static var sourceDir: String? {
        guard let dir = Bundle.main.object(forInfoDictionaryKey: "MurmurSourceDir") as? String,
              FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git"))
        else { return nil }
        return dir
    }

    static var buildCommit: String {
        Bundle.main.object(forInfoDictionaryKey: "MurmurCommit") as? String ?? "?"
    }

    static var logFile: URL { Paths.configDir.appendingPathComponent("update.log") }

    /// Fetches and compares against the commit this app was built from.
    /// Blocking — call off the main thread.
    static func check() -> Status? {
        guard let dir = sourceDir else { return nil }
        guard run("git fetch -q origin main", in: dir).status == 0 else { return nil }
        let base = buildCommit == "?" ? "HEAD" : buildCommit
        let log = run("git log --format=%s \(base)..origin/main", in: dir)
        guard log.status == 0 else { return nil }
        let lines = log.output.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("Merge ") }
        return Status(behind: lines.count, summary: lines)
    }

    /// Pulls and rebuilds in a detached shell. On success `build.sh` quits
    /// this app and opens the new one; `onFailure` runs (on the main thread)
    /// only if the shell exits with an error.
    static func install(onFailure: @escaping () -> Void) {
        guard let dir = sourceDir else { onFailure(); return }
        // Leave whatever branch an older manual update left checked out, but
        // never discard local edits: --ff-only refuses rather than merges.
        let script = """
        set -e
        echo "== $(date) — updating from $(pwd)"
        git fetch origin main
        git checkout main
        git merge --ff-only origin/main
        ./build.sh --install
        """
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let out = (try? FileHandle(forWritingTo: logFile)) ?? FileHandle.nullDevice

        let proc = Process()
        // A login shell, so PATH matches Terminal (git, swift, brew tools).
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", script]
        proc.currentDirectoryURL = URL(fileURLWithPath: dir)
        proc.standardOutput = out
        proc.standardError = out
        proc.terminationHandler = { p in
            Log.write("update finished with status \(p.terminationStatus) — see update.log")
            if p.terminationStatus != 0 { DispatchQueue.main.async(execute: onFailure) }
        }
        do {
            try proc.run()
            Log.write("update started from \(dir)")
        } catch {
            Log.write("update failed to start: \(error.localizedDescription)")
            onFailure()
        }
    }

    private static func run(_ command: String, in dir: String) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
