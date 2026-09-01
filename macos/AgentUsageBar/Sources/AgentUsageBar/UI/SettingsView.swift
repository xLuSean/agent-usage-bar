import AppKit
import SwiftUI
import UsageMeterCore

enum SettingsTab: Hashable {
    case providers
    case dataSources
    case diagnostics
    case about
}

/// The real settings window's content.
///
/// Settings live here rather than in the popover because the popover is transient —
/// it closes the moment focus moves, which makes it a poor place to change anything
/// you want to see the effect of.
struct SettingsView: View {
    let model: AppModel
    let initiallyExpandedDiagnosticEntryIDs: Set<UUID>
    @State private var selectedTab: SettingsTab

    /// Sized on the tab *content*, not on the `TabView`. Constraining the TabView
    /// itself leaves its tab strip no room and the strip gets clipped, because the
    /// strip is drawn outside the content area rather than inside it.
    static let contentSize = NSSize(width: 460, height: 380)

    init(
        model: AppModel,
        initialTab: SettingsTab = .providers,
        initiallyExpandedDiagnosticEntryIDs: Set<UUID> = []
    ) {
        self.model = model
        self.initiallyExpandedDiagnosticEntryIDs = initiallyExpandedDiagnosticEntryIDs
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ProvidersSettingsTab(model: model, bindableModel: model)
                .frame(width: Self.contentSize.width, height: Self.contentSize.height)
                .tabItem { Label("Providers", systemImage: "gauge.with.dots.needle.bottom.50percent") }
                .tag(SettingsTab.providers)
            DeveloperSettingsTab(model: model, bindableModel: model)
                .frame(width: Self.contentSize.width, height: Self.contentSize.height)
                .tabItem { Label("Data Sources", systemImage: "flask") }
                .tag(SettingsTab.dataSources)
            DiagnosticsSettingsTab(
                model: model,
                bindableModel: model,
                initiallyExpandedEntryIDs: initiallyExpandedDiagnosticEntryIDs
            )
                .frame(width: Self.contentSize.width, height: Self.contentSize.height)
                .tabItem { Label("Diagnostics", systemImage: "doc.text.magnifyingglass") }
                .tag(SettingsTab.diagnostics)
            AboutTab(model: model)
                .frame(width: Self.contentSize.width, height: Self.contentSize.height)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .environment(\.locale, model.displayLanguage.locale)
    }
}

private struct DiagnosticsSettingsTab: View {
    let model: AppModel
    @Bindable var bindableModel: AppModel
    @State private var expandedEntryIDs: Set<UUID>
    @State private var copiedEntryID: UUID?

    init(
        model: AppModel,
        bindableModel: AppModel,
        initiallyExpandedEntryIDs: Set<UUID> = []
    ) {
        self.model = model
        self.bindableModel = bindableModel
        _expandedEntryIDs = State(initialValue: initiallyExpandedEntryIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(
                    model.displayLanguage.text(chinese: "保存錯誤紀錄", english: "Keep error history"),
                    selection: $bindableModel.diagnosticRetention
                ) {
                    ForEach(DiagnosticRetentionPeriod.allCases) { period in
                        Text(verbatim: model.displayLanguage.text(
                            chinese: "\(period.rawValue) 天",
                            english: "\(period.rawValue) days"
                        ))
                        .tag(period)
                    }
                }
                .pickerStyle(.segmented)

                Button(
                    model.displayLanguage.text(chinese: "清除紀錄", english: "Clear Log"),
                    role: .destructive
                ) {
                    model.clearDiagnosticLog()
                }
                .disabled(model.diagnosticEntries.isEmpty)
            }

            GroupBox {
                if model.diagnosticEntries.isEmpty {
                    ContentUnavailableView(
                        model.displayLanguage.text(chinese: "沒有錯誤紀錄", english: "No Error History"),
                        systemImage: "checkmark.circle",
                        description: Text(model.displayLanguage.text(
                            chinese: "查詢失敗時，這裡只會保存時間、供應商與錯誤類型。",
                            english: "Failed queries will record only the time, provider, and error category."
                        ))
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.diagnosticEntries) { entry in
                                DisclosureGroup(isExpanded: expansionBinding(for: entry.id)) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(verbatim: entry.detailMessage(locale: model.displayLanguage.locale))
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)

                                        HStack {
                                            Spacer()
                                            Button {
                                                copyDiagnostic(entry)
                                            } label: {
                                                Label(
                                                    copiedEntryID == entry.id ?
                                                        model.displayLanguage.text(chinese: "已複製", english: "Copied") :
                                                        model.displayLanguage.text(chinese: "複製訊息", english: "Copy Message"),
                                                    systemImage: copiedEntryID == entry.id ? "checkmark" : "doc.on.doc"
                                                )
                                            }
                                            .accessibilityLabel(model.displayLanguage.text(
                                                chinese: "複製這筆完整診斷訊息",
                                                english: "Copy this complete diagnostic message"
                                            ))
                                        }
                                    }
                                    .padding(.top, 8)
                                    .padding(.leading, 22)
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(verbatim: entry.provider.displayName)
                                            .font(.callout.weight(.semibold))
                                            .frame(width: 58, alignment: .leading)
                                        Text(verbatim: entry.kind.displayName(locale: model.displayLanguage.locale))
                                            .font(.callout)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(verbatim: TimeFormatting.dateAndTime(
                                            entry.occurredAt,
                                            locale: model.displayLanguage.locale
                                        ))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 7)
                                if entry.id != model.diagnosticEntries.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
            } label: {
                Label(
                    model.displayLanguage.text(chinese: "最近的查詢錯誤", english: "Recent Query Errors"),
                    systemImage: "exclamationmark.bubble"
                )
            }
            .frame(maxHeight: .infinity)

            Text(model.displayLanguage.text(
                chinese: "展開紀錄可查看並複製 App 產生的完整診斷。為保護隱私，內容不包含原始回應、憑證、執行檔路徑或供應商提供的任意文字；最多保存最新 \(DiagnosticLogStore.maximumEntries) 筆。",
                english: "Expand an entry to view and copy the complete app-authored diagnostic. For privacy, it excludes raw responses, credentials, executable paths, and arbitrary provider text. At most the newest \(DiagnosticLogStore.maximumEntries) entries are kept."
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func expansionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedEntryIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedEntryIDs.insert(id)
                } else {
                    expandedEntryIDs.remove(id)
                }
            }
        )
    }

    private func copyDiagnostic(_ entry: DiagnosticLogEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(
            entry.copyText(locale: model.displayLanguage.locale),
            forType: .string
        ) else { return }
        copiedEntryID = entry.id
    }
}

private struct ProvidersSettingsTab: View {
    let model: AppModel

    @Bindable var bindableModel: AppModel
    @State private var launchFailure: String?

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $bindableModel.displayLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.displayName).tag(language)
                    }
                }
                Toggle("Launch at Login", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { launchFailure = LaunchAtLogin.setEnabled($0) }
                ))
                if let launchFailure {
                    Label(launchFailure, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else if let status = LaunchAtLogin.statusDescription(language: model.displayLanguage) {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
            } header: {
                Text("General")
            }

            Section {
                Picker("Menu Bar Layout", selection: $bindableModel.menuBarLayout) {
                    ForEach(MenuBarLayout.allCases) { layout in
                        Text(verbatim: layout.displayName(language: model.displayLanguage)).tag(layout)
                    }
                }
                if model.menuBarLayout == .combined {
                    Text("Draws both gauges in one icon, using about half the width. Each provider keeps its letter and outline color, so they remain distinguishable. Use this when menu bar space is limited.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Layout")
            }

            Section {
                ForEach(model.presenters, id: \.provider) { presenter in
                    ProviderSettingsRow(model: model, presenter: presenter)
                }
            } footer: {
                Text("The outline color identifies the provider, while the fill height shows the percentage used. The letter is a second, color-independent cue for color-vision differences or similar outline colors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.allProvidersDisabled {
                Section {
                    Label(
                        "When both providers are disabled, a neutral menu bar icon remains as an entry point so you can reopen Settings.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSettingsRow: View {
    let model: AppModel
    @Bindable var presenter: ProviderPresenter

    private var placement: StatusBarController.MenuBarPlacement? {
        guard presenter.settings.isEnabled else { return nil }
        return model.menuBarPlacement?(presenter.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $presenter.settings.isEnabled) {
                HStack(spacing: 6) {
                    Text(presenter.provider.identityLetter)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(presenter.settings.identityColor.nsColor))
                    Text(model.displayLanguage.text(
                        chinese: "顯示 \(presenter.provider.displayName) 量表",
                        english: "Show \(presenter.provider.displayName) gauge"
                    ))
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Outline Color")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $presenter.settings.identityColor) {
                        ForEach(IdentityColor.allCases) { color in
                            Text(verbatim: color.displayName(language: model.displayLanguage)).tag(color)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                GridRow(alignment: .firstTextBaseline) {
                    Text(model.displayLanguage.text(
                        chinese: presenter.provider == .codex ? "額度更新頻率" : "更新頻率",
                        english: presenter.provider == .codex ? "Quota Refresh" : "Refresh Interval"
                    ))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $presenter.settings.refreshInterval) {
                        ForEach(RefreshInterval.allCases) { interval in
                            let name = interval.displayName(locale: model.displayLanguage.locale)
                            Text(verbatim: interval.isRecommended(for: presenter.provider)
                                ? model.displayLanguage.text(chinese: "\(name)（建議）", english: "\(name) (recommended)")
                                : name)
                                .tag(interval)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if presenter.provider == .codex {
                    GridRow(alignment: .firstTextBaseline) {
                        Text(model.displayLanguage.text(
                            chinese: "Token 更新頻率",
                            english: "Token Refresh"
                        ))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $presenter.codexTokenRefreshInterval) {
                            ForEach(CodexTokenRefreshInterval.allCases) { tokenInterval in
                                let name = tokenInterval.displayName(language: model.displayLanguage)
                                Text(verbatim: tokenInterval == .recommended
                                    ? model.displayLanguage.text(
                                        chinese: "\(name)（建議）",
                                        english: "\(name) (recommended)"
                                    )
                                    : name)
                                    .tag(tokenInterval)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    GridRow(alignment: .firstTextBaseline) {
                        Text(model.displayLanguage.text(
                            chinese: "Token 圖表範圍",
                            english: "Token Chart Range"
                        ))
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { model.codexTokenHistoryPeriod },
                            set: { model.codexTokenHistoryPeriod = $0 }
                        )) {
                            ForEach(CodexTokenHistoryPeriod.allCases) { period in
                                Text(verbatim: model.displayLanguage.text(
                                    chinese: "\(period.rawValue) 天",
                                    english: "\(period.rawValue) days"
                                ))
                                .tag(period)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                GridRow(alignment: .firstTextBaseline) {
                    Text("Data Status")
                        .foregroundStyle(.secondary)
                    Text(verbatim: presenter.state.statusLabel(locale: model.displayLanguage.locale))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if let placement {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Menu Bar Display")
                            .foregroundStyle(.secondary)
                        Text(verbatim: placement.displayName(language: model.displayLanguage))
                            .foregroundStyle(placement.isDisplayed ? Color.secondary : Color.orange)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .font(.callout)
            .disabled(!presenter.settings.isEnabled)

            let interval = presenter.settings.refreshInterval
            if presenter.provider == .claude {
                Text(model.displayLanguage.text(
                    chinese: "每天約 \(interval.refreshesPerDay) 次更新。頻率較高不一定更即時，因為 Claude Code 可能回傳快取資料。",
                    english: "About \(interval.refreshesPerDay) updates per day. More frequent updates may not be fresher because Claude Code can return cached data."
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let caution = interval.caution(locale: model.displayLanguage.locale) {
                    Label(caution, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                let tokenInterval = presenter.codexTokenRefreshInterval
                Text(model.displayLanguage.text(
                    chinese: "額度與 Token 統計使用獨立排程，約每天更新 \(interval.refreshesPerDay) 次與 \(tokenInterval.refreshesPerDay) 次；按「重新整理」會同時更新兩者。圖表範圍只影響顯示，不會刪除 Codex 回傳的資料。",
                    english: "Quota and token statistics use separate schedules: about \(interval.refreshesPerDay) and \(tokenInterval.refreshesPerDay) updates per day. Refresh updates both. Chart Range affects only what is shown and does not delete Codex data."
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let explanation = placement?.explanation(language: model.displayLanguage) {
                Label(explanation, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DeveloperSettingsTab: View {
    let model: AppModel
    @Bindable var bindableModel: AppModel

    var body: some View {
        Form {
            ClaudeExecutableSettings(model: model)

            CodexExecutableSettings(model: model)

            Section {
                Text("Claude Code answers `/usage` from the server when it can reach it, and from its own local cache when it cannot. Verified: the command still returns figures with the network off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("A cached reading carries no as-of time, so the app bounds it by the reset time instead: once a reading's window has ended, it is reported as unavailable rather than shown. What this does not catch is staleness within the current window — up to five hours for the session limit.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Rate limits apply per account. Because the query now runs through Claude Code itself rather than a direct call from this app, throttling is handled by the CLI — which also means a throttled query may return cached figures instead of an explicit error.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("How Fresh the Claude Figures Are")
            }

        }
        .formStyle(.grouped)
    }
}

private struct ClaudeExecutableSettings: View {
    let model: AppModel
    @State private var draft = ""

    private var normalizedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedPath: Result<URL, UsageError> {
        do {
            let path = normalizedDraft.isEmpty ? nil : normalizedDraft
            return .success(try ClaudeExecutableLocator(configuredPath: path).locate())
        } catch let error as UsageError {
            return .failure(error)
        } catch {
            return .failure(.claudeExecutableNotFound)
        }
    }

    var body: some View {
        Section {
            TextField("Leave blank to auto-detect", text: $draft)
                .font(.caption.monospaced())
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.setClaudeExecutablePath(draft) }
            HStack {
                Button("Apply") { model.setClaudeExecutablePath(draft) }
                    .disabled(normalizedDraft == model.claudeExecutablePath)
                Button("Use Auto-Detection") {
                    draft = ""
                    model.setClaudeExecutablePath("")
                }
                .disabled(model.claudeExecutablePath.isEmpty && normalizedDraft.isEmpty)
            }
            switch resolvedPath {
            case .success(let url):
                Label(url.path, systemImage: "checkmark.circle")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .failure(let error):
                Label(error.shortDescription(locale: model.displayLanguage.locale), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Command Run") {
                Text(verbatim: "claude " + ClaudeUsageCommand.arguments.joined(separator: " "))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
            Text("The app executes this file directly with those fixed arguments. It does not use a shell, and the arguments cannot be changed from settings or influenced by a response. The query is read-only: it runs no model and consumes no conversation quota.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The app never signs you in. If Claude Code is signed out, the panel offers `claude` for you to copy and run yourself.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("Claude Code Executable")
        } footer: {
            Text("Since 0.3.0 this app no longer reads your Keychain credential. Claude Code handles its own sign-in.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onAppear { draft = model.claudeExecutablePath }
    }
}

private struct CodexExecutableSettings: View {
    let model: AppModel
    @State private var draft = ""

    private var normalizedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedPath: Result<URL, UsageError> {
        do {
            let path = normalizedDraft.isEmpty ? nil : normalizedDraft
            return .success(try CodexExecutableLocator(configuredPath: path).locate())
        } catch let error as UsageError {
            return .failure(error)
        } catch {
            return .failure(.codexExecutableNotFound)
        }
    }

    var body: some View {
        Section {
            TextField("Leave blank to auto-detect", text: $draft)
                .font(.caption.monospaced())
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.setCodexExecutablePath(draft) }
            HStack {
                Button("Apply") { model.setCodexExecutablePath(draft) }
                    .disabled(normalizedDraft == model.codexExecutablePath)
                Button("Use Auto-Detection") {
                    draft = ""
                    model.setCodexExecutablePath("")
                }
                .disabled(model.codexExecutablePath.isEmpty && normalizedDraft.isEmpty)
            }
            switch resolvedPath {
            case .success(let url):
                Label(url.path, systemImage: "checkmark.circle")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .failure(let error):
                Label(error.shortDescription(locale: model.displayLanguage.locale), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("The app uses Process to execute this file directly with the fixed arguments `app-server --listen stdio://`. It does not use a shell or start a sign-in flow.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("Codex CLI")
        }
        .onAppear { draft = model.codexExecutablePath }
    }
}

private struct AboutTab: View {
    let model: AppModel

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (build \(build))"
    }

    /// Which source this build came from. Blank for a build run straight from Xcode,
    /// which is itself the useful signal — packaged builds always carry one.
    private var sourceCommit: String? {
        let commit = Bundle.main.infoDictionary?["AUBSourceCommit"] as? String
        guard let commit, !commit.isEmpty else { return nil }
        return commit
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Agent Usage Bar")
                .font(.title2).bold()
            Text(model.displayLanguage.text(chinese: "版本 \(version)", english: "Version \(version)"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(sourceCommit.map {
                model.displayLanguage.text(chinese: "原始碼 \($0)", english: "Source \($0)")
            } ?? model.displayLanguage.text(chinese: "本機開發建置", english: "Local development build"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            // Required, not decorative: the app draws its own artwork precisely so it
            // makes no claim to either vendor's brand, and saying so is part of that.
            Text("This app is not affiliated with or endorsed by Anthropic or OpenAI. All icons are original designs and do not use official logos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
