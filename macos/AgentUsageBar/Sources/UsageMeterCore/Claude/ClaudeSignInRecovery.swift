/// Recovery guidance for Claude Code sign-in failures.
///
/// This type exposes only text for the user to copy. The app runs exactly one Claude
/// command — the read-only `/usage` query in `ClaudeUsageCommand` — and nothing here
/// adds a second one. It never starts a sign-in flow and never writes credentials.
///
/// # Why not just run `claude` for the user
///
/// It was tried. Signing in is interactive, and the commands that renew a credential do
/// so as an *undocumented side effect* of needing one — and an earlier attempt damaged
/// the user's login state. Renewal is not a command's contract, so there is nothing
/// to depend on. Handing the user a command to run in
/// their own terminal is the whole remedy.
///
/// Renamed from `ClaudeCredentialRecovery` in 0.3.0: the app no longer touches a
/// credential, so naming this after one described a job it does not do.
public enum ClaudeSignInRecovery: Sendable {
    public static let launchCommand = "claude"

    /// The one failure a copied command can fix.
    ///
    /// A missing executable needs an install, not a command; an outdated build needs an
    /// update whose form depends on how it was installed. Offering `claude` for either
    /// would be a button that cannot work.
    ///
    /// The old `setup-token` / missing-scope case is gone with the HTTP path: this app
    /// no longer inspects token scopes, so a token that cannot answer `/usage` now
    /// surfaces as whatever the CLI itself reports.
    public static func command(for error: UsageError?) -> String? {
        switch error {
        case .claudeNotSignedIn: launchCommand
        default: nil
        }
    }

    public static func isAvailable(for error: UsageError?) -> Bool {
        command(for: error) != nil
    }
}
