import AppKit
import Sparkle

/// Automatic updates through Sparkle. The feed lives at robodust.muhraufan.com, and an installed
/// copy only accepts an update signed with the private key in the developer's keychain.
final class Updates: NSObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!
    var isBusy: () -> Bool = { false }
    /// Dev only: reports progress and quits once an update is ready, which installs it.
    var testLog: String?

    var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    func start() {
        do { try updater.start() } catch { log("updater failed to start: \(error.localizedDescription)") }
    }

    /// Never interrupts a clean: a background check waits until the next one.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck != .updates && isBusy() {
            throw NSError(domain: "RoboDust", code: 1, userInfo: [NSLocalizedDescriptionKey: "A clean is running"])
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { log("found \(item.displayVersionString)") }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { log("no update"); if testLog != nil { NSApp.terminate(nil) } }
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { log("downloaded \(item.displayVersionString)") }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { log("aborted: \(error.localizedDescription)"); if testLog != nil { NSApp.terminate(nil) } }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        log("ready to install \(item.displayVersionString) on quit")
        if testLog != nil { DispatchQueue.main.async { NSApp.terminate(nil) } }
        return false
    }

    private func log(_ s: String) {
        guard let path = testLog, let d = (s + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: d) }
    }
}
