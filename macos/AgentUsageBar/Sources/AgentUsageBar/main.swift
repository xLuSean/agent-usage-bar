import AppKit
import Foundation

/// Menu bar utility: no Dock icon, no main window. `LSUIElement` in the bundled
/// Info.plist does the same thing for a launched .app; this covers running the
/// binary directly during development.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// These diagnostics construct AppModel or real NSStatusItems, so running them under
// the shipping bundle identity would give them the user's production UserDefaults and
// AppKit autosave domain. The verification script creates an ad-hoc-signed app copy
// whose unique identifier contains this marker. Refuse every other entry path rather
// than relying on a maintainer remembering the isolation procedure.
#if DEBUG
let preferenceSensitiveDiagnostics = [
    "--selftest",
    "--provider-transition-selftest",
    "--render-popover",
    "--instance-lock-hold",
]
if preferenceSensitiveDiagnostics.contains(where: CommandLine.arguments.contains),
   Bundle.main.bundleIdentifier?.contains(".verification-") != true {
    FileHandle.standardError.write(Data(
        "Preference-sensitive diagnostics require the isolated bundle created by scripts/verify.sh.\n".utf8
    ))
    exit(2)
}

// Development aid: render every gauge state to a PNG and exit without touching the
// menu bar. Not part of the product surface.
if let index = CommandLine.arguments.firstIndex(of: "--render-sheet"),
   index + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[index + 1]
    do {
        try MainActor.assumeIsolated { try GaugeContactSheet.write(to: path) }
        print(path)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("render-sheet failed: \(error)\n".utf8))
        exit(1)
    }
}

// Build step: emit the .iconset that make-app.sh turns into an .icns.
if let index = CommandLine.arguments.firstIndex(of: "--render-appicon"),
   index + 1 < CommandLine.arguments.count {
    let directory = CommandLine.arguments[index + 1]
    do {
        try MainActor.assumeIsolated { try AppIconRenderer.writeIconSet(to: directory) }
        print(directory)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("render-appicon failed: \(error)\n".utf8))
        exit(1)
    }
}

// Development aid: force the popover through a real layout pass and exit.
if let index = CommandLine.arguments.firstIndex(of: "--render-popover") {
    let path = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
    exit(MainActor.assumeIsolated { PopoverRenderCheck.run(writingTo: path) })
}

// Development aid: drive the real status bar wiring and exit.
if CommandLine.arguments.contains("--selftest") {
    let statusBarResult = MainActor.assumeIsolated { StatusBarSelfTest.run() }

    // Runs off the main actor on purpose — see runLivePathSmoke.
    //
    // Blocking the main thread here is only safe because that function is `nonisolated`.
    // While it inherited `@MainActor` from its enum, the task needed the very thread the
    // semaphore was holding, and this hung instead of running. Keep it nonisolated.
    let smokeResult = {
        nonisolated(unsafe) var result: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result = await StatusBarSelfTest.runLivePathSmoke()
            done.signal()
        }
        done.wait()
        return result
    }()

    exit(max(statusBarResult, smokeResult))
}

if CommandLine.arguments.contains("--provider-transition-selftest") {
    Task { @MainActor in
        exit(await StatusBarSelfTest.runProviderTransitionTests())
    }
    dispatchMain()
}
#endif

// A duplicate menu-bar copy would poll invisibly on its own schedule. A kernel-owned,
// per-user lock chooses exactly one owner; later copies yield without controlling it.
if !AppInstanceCoordinator.shouldContinueLaunching() {
    exit(0)
}

#if DEBUG
// Verification launches two isolated copies at the same time. The lock owner waits;
// the loser exits before constructing providers or touching preferences.
if CommandLine.arguments.contains("--instance-lock-hold") {
    Thread.sleep(forTimeInterval: 2)
    exit(0)
}
#endif

let delegate = AppDelegate()
application.delegate = delegate
application.run()
