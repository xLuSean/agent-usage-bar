/// Recovery guidance for Antigravity sign-in failures.
///
/// Exposes only text for the user to copy and run themselves. The app runs only the
/// read-only `/usage` query and never starts a sign-in flow or writes credentials.
public enum AntigravitySignInRecovery: Sendable {
    public static let launchCommand = "agy"

    public static func command(for error: UsageError?) -> String? {
        switch error {
        case .antigravityNotSignedIn: launchCommand
        default: nil
        }
    }

    public static func isAvailable(for error: UsageError?) -> Bool {
        command(for: error) != nil
    }
}
