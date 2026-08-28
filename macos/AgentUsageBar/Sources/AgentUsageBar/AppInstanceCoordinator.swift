import AppKit
import Darwin

/// Keeps duplicate menu-bar launches non-destructive. The first process to acquire the
/// per-user lock remains the owner; later copies ask it to surface Settings and exit
/// before creating providers. The kernel releases the lock if the owner exits or crashes.
@MainActor
enum AppInstanceCoordinator {
    static let showSettingsNotification = Notification.Name(
        "io.github.sean.AgentUsageBar.showSettings"
    )
    private static var lockFileDescriptor: Int32?

    static func shouldContinueLaunching() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              !bundleIdentifier.isEmpty else { return false }

        if lockFileDescriptor != nil {
            return true
        }

        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(bundleIdentifier).instance.lock", isDirectory: false)
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )

        guard descriptor >= 0 else {
            requestExistingInstance(bundleIdentifier: bundleIdentifier)
            return false
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            requestExistingInstance(bundleIdentifier: bundleIdentifier)
            return false
        }

        lockFileDescriptor = descriptor
        return true
    }

    private static func requestExistingInstance(bundleIdentifier: String) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let owner = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first { $0.processIdentifier != currentPID }

        owner?.activate()
        DistributedNotificationCenter.default().postNotificationName(
            showSettingsNotification,
            object: bundleIdentifier,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
