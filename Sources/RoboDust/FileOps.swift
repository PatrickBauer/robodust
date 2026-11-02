import AppKit
import Darwin

/// The only code in RoboDust that changes anything on disk. Every action re-checks each item
/// immediately before touching it, and anything that fails a check is left alone and reported.
enum FileOps {
    struct Target { var index: Int; var url: URL; var modified: Date?; var position: V2 }
    struct Trashed { var original: URL; var trashed: URL; var position: V2; var viaFinder = true }
    struct Outcome {
        var done: [Int] = []
        var failed: [(index: Int, reason: String)] = []
        var trashed: [Trashed] = []
    }

    /// nil means safe to act on. Never follows links: acts on the link itself, not what it points to.
    static func refusal(_ t: Target, root: URL) -> String? {
        let fm = FileManager.default
        let name = t.url.lastPathComponent
        if name.isEmpty || name == "." || name == ".." { return "Unsafe name" }
        let parent = t.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        if parent != root.resolvingSymlinksInPath().standardizedFileURL.path { return "Not directly on the desktop" }
        guard let attrs = try? fm.attributesOfItem(atPath: t.url.path) else { return "No longer there" }
        if let then = t.modified, let now = attrs[.modificationDate] as? Date, abs(now.timeIntervalSince(then)) > 1 {
            return "Changed during the clean"
        }
        return nil
    }

    static func delete(_ targets: [Target], root: URL, done: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var out = Outcome()
            for t in targets {
                if let why = refusal(t, root: root) { out.failed.append((t.index, why)); continue }
                do { try FileManager.default.removeItem(at: t.url); out.done.append(t.index) }
                catch { out.failed.append((t.index, error.localizedDescription)) }
            }
            log("delete", out, targets)
            DispatchQueue.main.async { done(out) }
        }
    }

    /// True for iCloud items that only exist as a stub on this Mac. Finder refuses these with an
    /// alert per item ("needs to be downloaded"). Folders count too, as they may hold stubs inside.
    static func isCloudOnly(_ url: URL) -> Bool {
        var st = stat()
        if lstat(url.path, &st) == 0, st.st_flags & UInt32(SF_DATALESS) != 0 { return true }
        guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isDirectoryKey]),
              v.isUbiquitousItem == true else { return false }
        return v.isDirectory == true || v.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current
    }

    /// Normal files go through Finder, because that's what makes Put Back work from the Trash.
    /// iCloud stubs go straight to the Trash, which needs no download and shows no alert.
    static func trash(_ targets: [Target], root: URL, done: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var out = Outcome()
            var allowed: [Target] = []
            var direct: [Target] = []
            for t in targets {
                if let why = refusal(t, root: root) { out.failed.append((t.index, why)) }
                else if isCloudOnly(t.url) { direct.append(t) }
                else { allowed.append(t) }
            }
            for t in direct {
                var result: NSURL?
                do {
                    try FileManager.default.trashItem(at: t.url, resultingItemURL: &result)
                    out.done.append(t.index)
                    if let r = result as URL? {
                        out.trashed.append(Trashed(original: t.url, trashed: r, position: t.position, viaFinder: false))
                    }
                } catch { out.failed.append((t.index, error.localizedDescription)) }
            }
            let script = """
            on run argv
                set out to ""
                tell application "Finder"
                    repeat with p in argv
                        try
                            set t to delete item (POSIX file (p as text) as alias)
                            set out to out & (p as text) & tab & POSIX path of (t as alias) & linefeed
                        on error e
                            set out to out & (p as text) & tab & linefeed
                        end try
                    end repeat
                end tell
                return out
            end run
            """
            var map: [String: String] = [:]
            var finderError: String?
            for batch in stride(from: 0, to: allowed.count, by: 80).map({ Array(allowed[$0..<min($0 + 80, allowed.count)]) }) {
                let r = osascript(script, batch.map { $0.url.path })
                if let e = r.error { finderError = e }
                for line in r.output.split(separator: "\n") {
                    let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                    if parts.count == 2, !parts[1].isEmpty { map[String(parts[0])] = String(parts[1]) }
                }
            }
            // The filesystem decides what happened, not the script's output.
            for t in allowed {
                if (try? FileManager.default.attributesOfItem(atPath: t.url.path)) == nil {
                    out.done.append(t.index)
                    if let to = map[t.url.path] {
                        out.trashed.append(Trashed(original: t.url, trashed: URL(fileURLWithPath: to), position: t.position))
                    }
                } else {
                    out.failed.append((t.index, finderError ?? "Finder couldn't move it"))
                }
            }
            log("trash", out, targets)
            DispatchQueue.main.async { done(out) }
        }
    }

    /// Moves items back out of the Trash to where they were, under their original names.
    static func undoTrash(_ items: [Trashed], done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Items that bypassed Finder come back the same way, for the same reason.
            let fm = FileManager.default
            var viaFinder: [Trashed] = []
            for t in items {
                if t.viaFinder { viaFinder.append(t); continue }
                if (try? fm.moveItem(at: t.trashed, to: t.original)) == nil { viaFinder.append(t) }
            }
            let script = """
            on run argv
                tell application "Finder"
                    repeat with i from 1 to (count of argv) by 3
                        set src to item i of argv
                        set destFolder to item (i + 1) of argv
                        set wanted to item (i + 2) of argv
                        try
                            set m to move item (POSIX file src as alias) to folder (POSIX file destFolder as alias)
                            if name of m is not wanted then set name of m to wanted
                        end try
                    end repeat
                end tell
            end run
            """
            for batch in stride(from: 0, to: viaFinder.count, by: 60).map({ Array(viaFinder[$0..<min($0 + 60, viaFinder.count)]) }) {
                _ = osascript(script, batch.flatMap { [$0.trashed.path, $0.original.deletingLastPathComponent().path, $0.original.lastPathComponent] })
            }
            let restored = items.filter { FileManager.default.fileExists(atPath: $0.original.path) }
            setPositions(restored.map { ($0.original, $0.position) }) { _ in
                appendLog("undo trash: restored \(restored.count) of \(items.count)")
                done(restored.count)
            }
        }
    }

    /// Tidy up changes where icons sit, never where files live.
    static func setPositions(_ moves: [(URL, V2)], done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            on run argv
                tell application "Finder"
                    repeat with i from 1 to (count of argv) by 3
                        try
                            set desktop position of item (POSIX file (item i of argv) as alias) to {(item (i + 1) of argv) as integer, (item (i + 2) of argv) as integer}
                        end try
                    end repeat
                end tell
            end run
            """
            var failure: String?
            for batch in stride(from: 0, to: moves.count, by: 60).map({ Array(moves[$0..<min($0 + 60, moves.count)]) }) {
                let r = osascript(script, batch.flatMap { [$0.0.path, String(Int($0.1.x.rounded())), String(Int($0.1.y.rounded()))] })
                if let e = r.error { failure = e }
            }
            DispatchQueue.main.async { done(failure) }
        }
    }

    /// Tidy can't work while Finder is keeping the desktop sorted, so this is checked first.
    static func desktopIsFreeform() -> Bool {
        let r = osascript("tell application \"Finder\" to get arrangement of icon view options of window of desktop as text", [])
        let arrangement = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return arrangement.isEmpty || arrangement == "not arranged"
    }

    /// File names travel as arguments, never inside script text, so no name can alter the script.
    static func osascript(_ source: String, _ args: [String]) -> (output: String, error: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return ("", error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus == 0 ? nil : (message?.isEmpty == false ? message : "Finder didn't respond"))
    }

    // MARK: - History, kept on this Mac only

    static var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RoboDust")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.log")
    }

    static func log(_ action: String, _ o: Outcome, _ targets: [Target]) {
        let byIndex = Dictionary(uniqueKeysWithValues: targets.map { ($0.index, $0.url.path) })
        var lines = ["\(action): \(o.done.count) done, \(o.failed.count) left alone"]
        lines += o.done.compactMap { byIndex[$0].map { "  done \($0)" } }
        lines += o.failed.compactMap { f in byIndex[f.index].map { "  left \($0) (\(f.reason))" } }
        appendLog(lines.joined(separator: "\n"))
    }

    static func appendLog(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(stamp)] \(text)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: historyURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: historyURL)
        }
    }

    // MARK: - iCloud test, on its own small test files in iCloud Drive

    static func iCloudTest() -> Bool {
        let fm = FileManager.default
        var allOK = true
        func check(_ name: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", name); if !ok { allOK = false } }
        func wait(_ body: (@escaping () -> Void) -> Void) {
            let s = DispatchSemaphore(value: 0)
            body { s.signal() }
            while s.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        func mod(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        func isStub(_ u: URL) -> Bool { var st = stat(); return lstat(u.path, &st) == 0 && st.st_flags & UInt32(SF_DATALESS) != 0 }
        let drive = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let root = drive.appendingPathComponent("robodust-selftest-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: root) }
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { print("no iCloud Drive access:", error.localizedDescription); return false }
        let payload = Data(repeating: 0x78, count: 200_000)
        let names = ["trash-me.bin", "delete-me.bin"]
        let urls = names.map { root.appendingPathComponent($0) }
        urls.forEach { fm.createFile(atPath: $0.path, contents: payload) }
        let sub = root.appendingPathComponent("folder"); try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let inner = sub.appendingPathComponent("inner.bin"); fm.createFile(atPath: inner.path, contents: payload)
        let all = urls + [inner]

        // Upload, then evict, leaving the same kind of stub that "Optimize Mac Storage" leaves.
        var evicted = false
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            for u in all where !isStub(u) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/brctl"); p.arguments = ["evict", u.path]
                p.standardOutput = Pipe(); p.standardError = Pipe(); try? p.run(); p.waitUntilExit()
            }
            if all.allSatisfy(isStub) { evicted = true; break }
            Thread.sleep(forTimeInterval: 5)
        }
        check("test files became cloud-only stubs", evicted)
        guard evicted else { return false }
        check("stub detected as cloud-only", isCloudOnly(urls[0]))
        check("folder treated as possibly holding stubs", isCloudOnly(sub))

        var o = Outcome()
        let targets = [Target(index: 1, url: urls[0], modified: mod(urls[0]), position: V2(0, 0)),
                       Target(index: 2, url: sub, modified: mod(sub), position: V2(0, 0))]
        wait { fin in trash(targets, root: root) { o = $0; fin() } }
        for f in o.failed { print("  reason:", f.reason) }
        check("stub and folder moved to Trash without Finder", o.done.sorted() == [1, 2] && !fm.fileExists(atPath: urls[0].path) && o.trashed.allSatisfy { !$0.viaFinder })
        if let t = o.trashed.first(where: { $0.original == urls[0] }) {
            check("no download was needed: still a stub in the Trash", isStub(t.trashed))
            print("  trash location:", t.trashed.path.contains("Mobile Documents") ? "iCloud Drive trash" : "local Trash")
        }
        var restored = 0
        wait { fin in undoTrash(o.trashed) { restored = $0; fin() } }
        check("undo brings both back", restored == 2 && (try? fm.attributesOfItem(atPath: urls[0].path)) != nil)
        check("still a stub after undo", isStub(urls[0]))

        var d = Outcome()
        wait { fin in delete([Target(index: 3, url: urls[1], modified: mod(urls[1]), position: V2(0, 0))], root: root) { d = $0; fin() } }
        check("permanent delete works on a stub", d.done == [3] && (try? fm.attributesOfItem(atPath: urls[1].path)) == nil)
        return allOK
    }

    // MARK: - Self-test, on a throwaway folder only

    static func selfTest(sandbox: URL) -> Bool {
        let fm = FileManager.default
        var allOK = true
        func check(_ name: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", name); if !ok { allOK = false } }
        func wait(_ body: (@escaping () -> Void) -> Void) {
            let s = DispatchSemaphore(value: 0)
            body { s.signal() }
            while s.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        let root = sandbox.appendingPathComponent("desk"), outside = sandbox.appendingPathComponent("outside")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        func make(_ dir: URL, _ n: String) -> URL { let u = dir.appendingPathComponent(n); fm.createFile(atPath: u.path, contents: Data("x".utf8)); return u }
        func target(_ i: Int, _ u: URL, modified: Date? = nil) -> Target { Target(index: i, url: u, modified: modified, position: V2(0, 0)) }
        func mod(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }

        let plain = make(root, "plain.txt")
        let tricky = make(root, "it's \"odd\" & $(rm -rf x) name.txt")
        let keepOutside = make(outside, "outside.txt")
        let viaDots = root.appendingPathComponent("../outside/outside.txt")
        let changed = make(root, "changed.txt")
        let changedStamp = Date(timeIntervalSinceNow: -5000)
        let gone = root.appendingPathComponent("already-gone.txt")
        let folder = root.appendingPathComponent("folder")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = make(folder, "inner.txt")
        let linkTarget = make(outside, "link-target.txt")
        let link = root.appendingPathComponent("link.txt")
        try? fm.createSymbolicLink(at: link, withDestinationURL: linkTarget)

        var o = Outcome()
        wait { fin in
            delete([target(1, plain, modified: mod(plain)), target(2, tricky), target(3, keepOutside), target(4, viaDots),
                    target(5, changed, modified: changedStamp), target(6, gone), target(7, folder), target(8, link)], root: root) { o = $0; fin() }
        }
        check("deletes a normal file", !fm.fileExists(atPath: plain.path))
        check("deletes a file with quotes and shell characters in its name", !fm.fileExists(atPath: tricky.path))
        check("deletes a folder inside the root", !fm.fileExists(atPath: folder.path))
        check("refuses a file outside the root", fm.fileExists(atPath: keepOutside.path) && o.failed.contains { $0.index == 3 })
        check("refuses a ../ path escaping the root", fm.fileExists(atPath: keepOutside.path) && o.failed.contains { $0.index == 4 })
        check("refuses a file changed since it was collected", fm.fileExists(atPath: changed.path) && o.failed.contains { $0.index == 5 })
        check("reports a file that already vanished", o.failed.contains { $0.index == 6 })
        check("removes a link without touching what it points to", (try? fm.attributesOfItem(atPath: link.path)) == nil && fm.fileExists(atPath: linkTarget.path))
        check("empty root refused as parent", refusal(target(9, root), root: root) != nil)

        // One tiny file goes to the real Trash through Finder and comes straight back.
        let name = "robodust-self-test-\(UUID().uuidString.prefix(8)).txt"
        let t1 = make(root, name)
        var o2 = Outcome()
        wait { fin in trash([target(10, t1, modified: mod(t1))], root: root) { o2 = $0; fin() } }
        check("moves a file to the Trash", !fm.fileExists(atPath: t1.path) && o2.done == [10])
        check("gets the Trash location back", o2.trashed.count == 1)
        if o2.failed.first != nil { print("  reason:", o2.failed[0].reason) }
        var restored = 0
        wait { fin in undoTrash(o2.trashed) { restored = $0; fin() } }
        check("undo restores it under its original name", restored == 1 && fm.fileExists(atPath: t1.path))

        // Sets one real desktop icon to the spot it already occupies: proves the script, changes nothing.
        let before = osascript("tell application \"Finder\" to get desktop position of item 1 of desktop", [])
        let nameR = osascript("tell application \"Finder\" to get POSIX path of (item 1 of desktop as alias)", [])
        let nums = before.output.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Float($0) }
        if nums.count == 2 {
            var err: String? = "not run"
            wait { fin in setPositions([(URL(fileURLWithPath: nameR.output.trimmingCharacters(in: .whitespacesAndNewlines)), V2(nums[0], nums[1]))]) { err = $0; fin() } }
            let after = osascript("tell application \"Finder\" to get desktop position of item 1 of desktop", [])
            check("position script runs and leaves the icon where it was", err == nil && after.output == before.output)
        } else if osascript("tell application \"Finder\" to count items of desktop", []).output.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            print("SKIP position script: the desktop has no icons to check")
        } else { check("reads an icon position", false) }
        print("desktop freeform:", desktopIsFreeform())
        return allOK
    }
}
