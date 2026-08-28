import Foundation
import ServiceManagement

/// Registers the app to start when the user logs in.
///
/// A menu bar utility that has to be launched by hand is one the user will forget to
/// launch, and then the gauge is simply absent rather than wrong — which is worse,
/// because absence looks like the app is broken.
///
/// `SMAppService` keeps the registration in the system's own login-items list, so the
/// setting is visible and revocable in System Settings rather than being a hidden
/// entry only this app knows about. The trade-off is that macOS can refuse or defer:
/// the status is read back rather than assumed.
@MainActor
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// What macOS thinks, in words. `.requiresApproval` is the case worth surfacing —
    /// the request succeeded but the user has to approve it in System Settings, and
    /// silently showing the toggle as off would make that look like a failure.
    static var statusDescription: String? {
        statusDescription(language: .english)
    }

    static func statusDescription(language: AppLanguage) -> String? {
        switch SMAppService.mainApp.status {
        case .enabled: nil
        case .requiresApproval:
            language.text(
                chinese: "已要求，但需要你在「系統設定 → 一般 → 登入項目」中允許。",
                english: "Requested, but approval is required in System Settings > General > Login Items."
            )
        case .notFound:
            language.text(
                chinese: "系統找不到這個 App 的登入項目。把 App 放進「應用程式」資料夾後再試一次。",
                english: "macOS could not find this app's login item. Move the app to the Applications folder and try again."
            )
        case .notRegistered: nil
        @unknown default: nil
        }
    }

    /// Returns whether the request was accepted. Failure is reported rather than
    /// swallowed: a toggle that flips back with no explanation is worse than one that
    /// says why.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
