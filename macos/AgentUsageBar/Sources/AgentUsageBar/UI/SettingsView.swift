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
                            chinese: "查詢失敗後，可在這裡查看發生時間與原因。",
                            english: "When a query fails, its time and available details appear here."
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
                                            .frame(width: 82, alignment: .leading)
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
                    Text(model.displayLanguage.text(
                        chinese: "所有啟用中的供應商共用一個選單列項目，減少系統留白。每家保留字母與外框顏色；顯示雙時間窗時左側是 5 小時，右側是 7 天。",
                        english: "Combines all enabled providers in one status item to reduce system padding. Each keeps its letter and outline color, with 5 hours on the left and 7 days on the right when showing both windows."
                    ))
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
                        model.displayLanguage.text(
                            chinese: "所有供應商皆已停用時，選單列仍會保留一個中性圖示作為入口，方便隨時重新開啟設定。",
                            english: "When all providers are disabled, a neutral menu bar icon remains as an entry point so you can reopen Settings."
                        ),
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

    private var availableAntigravityGroups: [String] {
        var groups: [String] = []
        if let snapshotGroups = presenter.state.snapshot?.antigravityGroupNames, !snapshotGroups.isEmpty {
            groups.append(contentsOf: snapshotGroups)
        }
        if !groups.contains(AntigravityToolbarGroupSelection.defaultGroupName) {
            groups.insert(AntigravityToolbarGroupSelection.defaultGroupName, at: 0)
        }
        if case .group(let selected) = model.antigravityToolbarGroup, !groups.contains(selected) {
            groups.append(selected)
        }
        if case .group(let selected) = model.antigravityPopoverGroup, !groups.contains(selected) {
            groups.append(selected)
        }
        return groups
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
                    Text(verbatim: model.displayLanguage.text(
                        chinese: "選單列時間窗",
                        english: "Menu Bar Windows"
                    ))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $presenter.settings.toolbarWindows) {
                        ForEach(QuotaWindowDisplayMode.allCases) { mode in
                            Text(verbatim: mode.displayName(locale: model.displayLanguage.locale)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                GridRow(alignment: .firstTextBaseline) {
                    Text(verbatim: model.displayLanguage.text(
                        chinese: "詳情面板時間窗",
                        english: "Popover Windows"
                    ))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $presenter.settings.popoverWindows) {
                        ForEach(QuotaWindowDisplayMode.allCases) { mode in
                            Text(verbatim: mode.displayName(locale: model.displayLanguage.locale)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if presenter.provider == .antigravity {
                    GridRow(alignment: .firstTextBaseline) {
                        Text(verbatim: model.displayLanguage.text(
                            chinese: "選單列模型群組",
                            english: "Menu Bar Group"
                        ))
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { model.antigravityToolbarGroup },
                            set: { model.antigravityToolbarGroup = $0 }
                        )) {
                            ForEach(availableAntigravityGroups, id: \.self) { name in
                                Text(verbatim: name).tag(AntigravityToolbarGroupSelection.group(name))
                            }
                            Text(verbatim: AntigravityToolbarGroupSelection.highestUsed.displayName(
                                locale: model.displayLanguage.locale
                            ))
                                .tag(AntigravityToolbarGroupSelection.highestUsed)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    GridRow(alignment: .firstTextBaseline) {
                        Text(verbatim: model.displayLanguage.text(
                            chinese: "詳情面板群組",
                            english: "Popover Groups"
                        ))
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { model.antigravityPopoverGroup },
                            set: { model.antigravityPopoverGroup = $0 }
                        )) {
                            Text(verbatim: AntigravityPopoverGroupSelection.all.displayName(
                                locale: model.displayLanguage.locale
                            ))
                                .tag(AntigravityPopoverGroupSelection.all)
                            ForEach(availableAntigravityGroups, id: \.self) { name in
                                Text(verbatim: name).tag(AntigravityPopoverGroupSelection.group(name))
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
            switch presenter.provider {
            case .claude:
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
            case .codex:
                let tokenInterval = presenter.codexTokenRefreshInterval
                Text(model.displayLanguage.text(
                    chinese: "額度與 Token 統計使用獨立排程，約每天更新 \(interval.refreshesPerDay) 次與 \(tokenInterval.refreshesPerDay) 次；按「重新整理」會同時更新兩者。圖表範圍只影響顯示，不會刪除 Codex 回傳的資料。",
                    english: "Quota and token statistics use separate schedules: about \(interval.refreshesPerDay) and \(tokenInterval.refreshesPerDay) updates per day. Refresh updates both. Chart Range affects only what is shown and does not delete Codex data."
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .antigravity:
                Text(verbatim: model.displayLanguage.text(
                    chinese: "每天約 \(interval.refreshesPerDay) 次更新。若方案沒有 5 小時額度（例如 Free 方案），選單列會自動改為單槽 7 天顯示。",
                    english: "About \(interval.refreshesPerDay) updates per day. When a plan has no 5-hour window (such as the Free plan), the menu bar automatically shows a single 7-day gauge."
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let snapshot = presenter.state.snapshot, !snapshot.antigravityGroupNames.isEmpty {
                    if case .group(let selected) = model.antigravityToolbarGroup,
                       !snapshot.antigravityGroupNames.contains(selected),
                       let resolved = snapshot.resolvedAntigravityToolbarGroup(selection: model.antigravityToolbarGroup) {
                        Label(
                            model.displayLanguage.text(
                                chinese: "最新回應中未包含「\(selected)」，選單列目前改顯示「\(resolved)」。",
                                english: "\"\(selected)\" is not in the latest response; the menu bar is currently showing \"\(resolved)\"."
                            ),
                            systemImage: "info.circle"
                        )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if case .group(let selected) = model.antigravityPopoverGroup,
                       !snapshot.antigravityGroupNames.contains(selected) {
                        Label(
                            model.displayLanguage.text(
                                chinese: "最新回應中未包含「\(selected)」，詳情面板目前改顯示所有群組。",
                                english: "\"\(selected)\" is not in the latest response; the popover is currently showing all groups."
                            ),
                            systemImage: "info.circle"
                        )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
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

            AntigravityExecutableSettings(model: model)

            Section {
                Text("Claude Code attaches a structured usage report to `/usage`. When it could not reach the server, that report holds no figures, and the app marks the last reading as stale instead of showing the older numbers Claude Code still prints. Verified with the network blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("A reading can still be about a minute old, because Claude Code briefly reuses a fresh answer. An older Claude Code attaches no report; the app then reads the printed text, which can come from a local cache with no as-of time, and bounds it by the reset time. That does not catch staleness within the current window — up to five hours for the session limit.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Rate limits apply per account. The query runs through Claude Code itself rather than as a direct call from this app, so throttling is handled by the CLI. Whether a throttled lookup reports no figures or its last known ones has not been observed.")
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

private struct AntigravityExecutableSettings: View {
    let model: AppModel
    @State private var draft = ""

    private var normalizedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedPath: Result<URL, UsageError> {
        do {
            let path = normalizedDraft.isEmpty ? nil : normalizedDraft
            return .success(try AntigravityExecutableLocator(configuredPath: path).locate())
        } catch let error as UsageError {
            return .failure(error)
        } catch {
            return .failure(.antigravityExecutableNotFound)
        }
    }

    var body: some View {
        Section {
            TextField("Leave blank to auto-detect", text: $draft)
                .font(.caption.monospaced())
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.setAntigravityExecutablePath(draft) }
            HStack {
                Button("Apply") { model.setAntigravityExecutablePath(draft) }
                    .disabled(normalizedDraft == model.antigravityExecutablePath)
                Button("Use Auto-Detection") {
                    draft = ""
                    model.setAntigravityExecutablePath("")
                }
                .disabled(model.antigravityExecutablePath.isEmpty && normalizedDraft.isEmpty)
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
            LabeledContent(model.displayLanguage.text(chinese: "執行指令", english: "Command Run")) {
                Text(verbatim: "agy " + AntigravityUsageCommand.arguments.joined(separator: " ") + " --log-file <temp>/agy.log")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
            Text(verbatim: model.displayLanguage.text(
                chinese: "App 以固定參數直接執行此檔案，不經 shell，也不會啟動登入流程或消耗模型額度。CLI 日誌會導向 App 專用的固定暫存目錄，每次查詢前清空、結束後刪除；查詢時也會關閉 agy 自己的背景自動更新。",
                english: "The app executes this file directly with those fixed arguments. It does not use a shell, never starts a sign-in flow, and runs zero model turns. CLI logs go to one fixed temporary directory owned by the app, cleared before each query and removed afterward. Queries also turn off agy's own background auto-update."
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text(verbatim: model.displayLanguage.text(chinese: "Antigravity CLI（agy）", english: "Antigravity CLI (agy)"))
        }
        .onAppear { draft = model.antigravityExecutablePath }
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
            Text(verbatim: model.displayLanguage.text(
                chinese: "本 App 與 Anthropic、OpenAI 或 Google 均無隸屬關係，也未獲其背書。所有圖示為原創設計，未使用任何官方標誌。",
                english: "This app is not affiliated with or endorsed by Anthropic, OpenAI, or Google. All icons are original designs and do not use official logos."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
