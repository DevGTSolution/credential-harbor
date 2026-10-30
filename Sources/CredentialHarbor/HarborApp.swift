import AppKit
import HarborCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Theme

/// Colors for one look. Harbor is the default, taken from the lighthouse-key logo.
struct Palette {
    let bg, bg2, card, line, top, danger, accent, accentGlow, onAccent, text, muted, good: Color
    let dark: Bool
}

enum ThemeName: String, Codable, CaseIterable, Identifiable {
    case harbor = "Harbor", midnight = "Midnight", ember = "Ember", daylight = "Daylight"
    var id: String { rawValue }

    var palette: Palette {
        switch self {
        case .harbor:
            Palette(bg: Color(hex: 0x0E1A33), bg2: Color(hex: 0x172848), card: Color(hex: 0x1B2E52), line: .white.opacity(0.07),
                    top: Color(hex: 0xA3192B), danger: Color(hex: 0xD0414E), accent: Color(hex: 0xE2BC6E), accentGlow: Color(hex: 0xF6D58E),
                    onAccent: Color(hex: 0x0E1A33), text: Color(hex: 0xF3EBDD), muted: Color(hex: 0x9AA6BF), good: Color(hex: 0x4CC38A), dark: true)
        case .midnight:
            Palette(bg: Color(hex: 0x0B1220), bg2: Color(hex: 0x111B2E), card: Color(hex: 0x16233B), line: .white.opacity(0.07),
                    top: Color(hex: 0x1F4E79), danger: Color(hex: 0xE0565B), accent: Color(hex: 0x5EC4D6), accentGlow: Color(hex: 0x9BE3EE),
                    onAccent: Color(hex: 0x0B1220), text: Color(hex: 0xE6EEF7), muted: Color(hex: 0x8C9BB3), good: Color(hex: 0x4CC38A), dark: true)
        case .ember:
            Palette(bg: Color(hex: 0x141210), bg2: Color(hex: 0x1E1A17), card: Color(hex: 0x27211C), line: .white.opacity(0.07),
                    top: Color(hex: 0x7A2E12), danger: Color(hex: 0xE0565B), accent: Color(hex: 0xF0A04B), accentGlow: Color(hex: 0xF7C98B),
                    onAccent: Color(hex: 0x141210), text: Color(hex: 0xF2E9E1), muted: Color(hex: 0xA39A90), good: Color(hex: 0x6CC08B), dark: true)
        case .daylight:
            Palette(bg: Color(hex: 0xF6F3EE), bg2: Color(hex: 0xEEE8DE), card: .white, line: .black.opacity(0.08),
                    top: Color(hex: 0xD9B8BC), danger: Color(hex: 0xB0263A), accent: Color(hex: 0xA87A1F), accentGlow: Color(hex: 0xC8962E),
                    onAccent: .white, text: Color(hex: 0x1D2433), muted: Color(hex: 0x667085), good: Color(hex: 0x2E9D63), dark: false)
        }
    }
}

/// The active palette. Model.pull() sets it from Settings; RootView re-renders on change.
enum Theme {
    static var current = ThemeName.harbor.palette
    static var bg: Color { current.bg }
    static var bg2: Color { current.bg2 }
    static var card: Color { current.card }
    static var line: Color { current.line }
    static var top: Color { current.top }
    static var danger: Color { current.danger }
    static var accent: Color { current.accent }
    static var accentGlow: Color { current.accentGlow }
    static var onAccent: Color { current.onAccent }
    static var text: Color { current.text }
    static var muted: Color { current.muted }
    static var good: Color { current.good }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

let aiInstructions = """
Credentials: never ask me for passwords. Use the `harbor` CLI (Credential Harbor, /Users/Shared/CredentialHarbor/bin/harbor). \
`harbor list` shows the credentials you may use, with notes. Run commands with them injected: \
`harbor run --stdin AI-NAME -- ssh host 'sudo -S -p "" cmd'`, `harbor run --askpass AI-NAME -- ssh user@host cmd`, \
`harbor run -- curl -u '{{AI-NAME.user}}:{{AI-NAME}}' URL`, `harbor run --env VAR='{{AI-NAME}}' -- cmd`. \
Output is redacted. If harbor exits 77, tell me which AI- name you need or what it said; don't try to print or decode secrets. \
`harbor help` has details.
"""

// MARK: - App

@main
struct HarborApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup("Credential Harbor") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

enum Section: String, CaseIterable, Identifiable {
    case credentials = "Credentials", agents = "Agents", activity = "Activity", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .credentials: "key.fill"
        case .agents: "person.2.fill"
        case .activity: "waveform.path.ecg"
        case .settings: "gearshape.fill"
        }
    }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var config = Config()
    @Published var events: [Event] = []
    @Published var approved: [VaultEntry] = []
    @Published var candidates: [Candidate] = []
    @Published var section: Section = .credentials
    @Published var selectedCredential: String?
    @Published var selectedAgent: UUID?
    @Published var revealedKey: (agent: Agent, key: String)?
    @Published var addingCredential = false
    @Published var testing: Set<String> = []
    @Published var banner: String?
    @Published var brokerError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    init() {
        do { try Broker.start() } catch { brokerError = "\(error)" }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Store.shared.onChange = { [weak self] in Task { @MainActor in self?.pull() } }
        reload()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in Store.shared.prune(); self?.runDueTests() }
        }
        runDueTests()
    }

    func pull() {
        (config, events) = Store.shared.snapshot()
        Theme.current = config.settings.theme.palette
    }

    func reload() {
        pull()
        do {
            approved = try Vault.entries()
            let names = Set(approved.map(\.alias))
            candidates = try Vault.candidates().filter { !names.contains($0.alias) }
        } catch { banner = "\(error)" }
        if selectedCredential == nil { selectedCredential = approved.first?.alias }
        if selectedAgent == nil { selectedAgent = config.agents.first?.id }
    }

    func update(_ change: (inout Config) -> Void) { Store.shared.update(change); pull() }

    func meta(_ alias: String) -> CredentialMeta { config.credentials[alias] ?? CredentialMeta() }
    func agent(_ id: UUID?) -> Agent? { config.agents.first { $0.id == id } }

    func binding<T>(alias: String, _ path: WritableKeyPath<CredentialMeta, T>) -> Binding<T> {
        Binding(get: { self.meta(alias)[keyPath: path] },
                set: { value in self.update { $0.credentials[alias, default: CredentialMeta()][keyPath: path] = value } })
    }

    func binding<T>(agent id: UUID, _ path: WritableKeyPath<Agent, T>) -> Binding<T> {
        Binding(get: { self.agent(id)?[keyPath: path] ?? Agent(name: "", kind: .other)[keyPath: path] },
                set: { value in self.update { config in
                    if let index = config.agents.firstIndex(where: { $0.id == id }) { config.agents[index][keyPath: path] = value }
                } })
    }

    func allows(_ agentID: UUID, _ alias: String) -> Binding<Bool> {
        Binding(get: { self.agent(agentID)?.allowed.contains(alias) ?? false },
                set: { on in self.update { config in
                    guard let index = config.agents.firstIndex(where: { $0.id == agentID }) else { return }
                    if on { config.agents[index].allowed.insert(alias) } else { config.agents[index].allowed.remove(alias) }
                } })
    }

    /// Off the main thread: reading the original item can sit on a macOS prompt.
    func approve(_ item: Candidate) {
        banner = "Waiting for macOS to allow reading \(item.alias)… (the Keychain dialog may be behind other windows)"
        Task.detached {
            let error: String? = { do { try Vault.approve(item); return nil } catch { return "\(error)" } }()
            await MainActor.run {
                self.banner = error ?? "Approved \(item.alias). Tick which agents may use it."
                self.reload(); if error == nil { self.selectedCredential = item.alias }
            }
        }
    }

    func add(alias: String, username: String, note: String, secret: String) {
        do {
            try Vault.save(alias: alias, username: username, secret: secret)
            update { $0.credentials[alias, default: CredentialMeta()].note = note }
            banner = "Saved \(alias). Tick which agents may use it."
            selectedCredential = alias
        } catch { banner = "\(error)" }
        reload()
    }

    func revoke(_ alias: String) {
        do {
            try Vault.remove(alias)
            update { config in
                config.credentials[alias] = nil
                for index in config.agents.indices { config.agents[index].allowed.remove(alias) }
            }
            banner = "Revoked \(alias). The original Keychain item, if any, is untouched."
            selectedCredential = nil
        } catch { banner = "\(error)" }
        reload()
    }

    func addAgent() {
        let agent = Agent(name: "New agent", kind: .other)
        update { $0.agents.append(agent) }
        selectedAgent = agent.id
    }

    func removeAgent(_ id: UUID) {
        update { $0.agents.removeAll { $0.id == id } }
        selectedAgent = config.agents.first?.id
    }

    func generateKey(_ id: UUID) {
        guard let agent = agent(id) else { return }
        revealedKey = (agent, Store.shared.newKey(for: id))
        pull()
    }

    /// Runs as the owner with the credential on stdin, in $HARBOR_PASSWORD/$HARBOR_USER, and for ssh/sudo -A prompts.
    func runTest(_ alias: String) {
        let command = meta(alias).test
        guard !command.isEmpty, !testing.contains(alias) else { return }
        testing.insert(alias)
        Task.detached {
            let health: Health
            do {
                let secret = try Vault.secret(alias), user = try Vault.username(alias)
                let spec = RunSpec(env: ["HARBOR_PASSWORD": "{{\(alias)}}", "HARBOR_USER": "{{\(alias).user}}"],
                                   askpass: alias, stdin: alias, command: ["/bin/sh", "-c", command])
                let collected = OutputBox()
                let status = try Runner.execute(spec, secrets: [alias: secret], usernames: [alias: user],
                                                askpassExecutable: Wire.cliPath, timeout: 30) { data, _ in collected.append(data) }
                health = Health(ok: status == 0, date: Date(), output: status == 0 ? collected.text : "exit \(status)\n\(collected.text)")
            } catch { health = Health(ok: false, date: Date(), output: "\(error)") }
            await MainActor.run {
                self.update { $0.credentials[alias, default: CredentialMeta()].health = health }
                self.testing.remove(alias)
            }
        }
    }

    func runDueTests() {
        for entry in approved where !meta(entry.alias).test.isEmpty {
            if let last = meta(entry.alias).health?.date, Date().timeIntervalSince(last) < 86400 { continue }
            runTest(entry.alias)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { banner = "Launch at login: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "harbor-activity.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder.iso.encode(events).write(to: url); banner = "Exported \(events.count) events." }
        catch { banner = "\(error)" }
    }

    func copy(_ text: String, _ note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        banner = note
    }
}

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.withLock { if data.count < 4000 { data.append(chunk) } } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } }
}

// MARK: - Root + sidebar

struct RootView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: 232)
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                if let banner = model.banner { Banner(text: banner) }
                Group {
                    switch model.section {
                    case .credentials: CredentialsView()
                    case .agents: AgentsView()
                    case .activity: ActivityView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.bg)
        }
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(Theme.current.dark ? .dark : .light)
        .id(model.config.settings.theme) // every view re-reads Theme
        .ignoresSafeArea()
        .sheet(isPresented: $model.addingCredential) { AddCredentialSheet() }
        .sheet(isPresented: Binding(get: { model.revealedKey != nil }, set: { if !$0 { model.revealedKey = nil } })) { KeySheet() }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                if let logo = Bundle.main.image(forResource: "logo") {
                    Image(nsImage: logo).resizable().frame(width: 84, height: 84)
                        .shadow(color: Theme.accentGlow.opacity(0.35), radius: 18)
                }
                Text("Credential Harbor").font(.system(size: 17, weight: .bold, design: .rounded))
                StatusPill()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 44)

            VStack(spacing: 4) {
                ForEach(Section.allCases) { section in
                    SidebarRow(section: section, count: count(section))
                }
            }

            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("harbor CLI").font(.caption2.weight(.semibold)).foregroundStyle(Theme.muted)
                Text(Wire.cliPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 14)
        .background(
            LinearGradient(colors: [Theme.top.opacity(0.55), Theme.bg2, Theme.bg], startPoint: .top, endPoint: .bottom)
        )
    }

    func count(_ section: Section) -> Int? {
        switch section {
        case .credentials: model.approved.count
        case .agents: model.config.agents.count
        default: nil
        }
    }
}

struct StatusPill: View {
    @EnvironmentObject var model: Model
    var body: some View {
        let (label, color): (String, Color) =
            model.brokerError != nil ? ("Broker offline", Theme.danger)
            : model.config.settings.pauseAll ? ("Paused", Theme.danger) : ("Active", Theme.good)
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(color.opacity(0.18), in: Capsule())
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: Model
    let section: Section
    let count: Int?

    var body: some View {
        let selected = model.section == section
        Button { model.section = section } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon).frame(width: 18)
                Text(section.rawValue).fontWeight(selected ? .semibold : .regular)
                Spacer()
                if let count { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(selected ? Theme.accentGlow : Theme.text.opacity(0.85))
            .background(selected ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Banner: View {
    @EnvironmentObject var model: Model
    let text: String
    var body: some View {
        HStack {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
            Text(text).font(.callout)
            Spacer()
            Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .padding(.top, 28)
        .background(Theme.accent.opacity(0.12))
    }
}

// MARK: - Shared pieces

struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline) }
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}

/// Label on the left, switch pinned to the right edge of the card.
struct RightSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.6), radius: 3) }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(Theme.muted)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 24).padding(.top, 40).padding(.bottom, 16)
    }
}

struct GoldButton: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(destructive ? .white : Theme.onAccent)
            .background(destructive ? Theme.danger : Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct Placeholder: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(Theme.accent.opacity(0.6))
            Text(text).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

func ago(_ date: Date?) -> String {
    guard let date else { return "never used" }
    return "used " + date.formatted(.relative(presentation: .named))
}

// MARK: - Credentials

struct CredentialsView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PageHeader(title: "Credentials", subtitle: "Keychain items AIs can use") {
                    Button { model.addingCredential = true } label: { Label("Add", systemImage: "plus") }.buttonStyle(GoldButton())
                }
                ScrollView {
                    VStack(spacing: 8) {
                        if model.approved.isEmpty { Text("Nothing approved yet.").foregroundStyle(Theme.muted).padding() }
                        ForEach(model.approved) { entry in CredentialCard(entry: entry) }
                        if !model.candidates.isEmpty {
                            HStack {
                                Text("FOUND IN YOUR KEYCHAIN").font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
                                Spacer()
                                Button("Rescan") { model.reload() }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
                            }
                            .padding(.top, 14)
                            ForEach(model.candidates) { item in CandidateRow(item: item) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
            .frame(width: 340)
            Rectangle().fill(Theme.line).frame(width: 1)
            if let alias = model.selectedCredential, let entry = model.approved.first(where: { $0.alias == alias }) {
                CredentialDetail(entry: entry).id(alias)
            } else {
                Placeholder(icon: "key.horizontal", text: "Select a credential, or add one.\nName Keychain items AI-Something to have them show up here.")
            }
        }
    }
}

struct CredentialCard: View {
    @EnvironmentObject var model: Model
    let entry: VaultEntry

    var body: some View {
        let meta = model.meta(entry.alias)
        let selected = model.selectedCredential == entry.alias
        let users = model.config.agents.filter { $0.allowed.contains(entry.alias) }.count
        Button { model.selectedCredential = entry.alias } label: {
            HStack(spacing: 12) {
                Image(systemName: "key.fill").font(.system(size: 14)).foregroundStyle(Theme.onAccent)
                    .frame(width: 32, height: 32).background(Theme.accent, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.alias).font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(meta.note.isEmpty ? (entry.username.isEmpty ? "password only" : entry.username) : meta.note)
                        .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Dot(color: meta.health.map { $0.ok ? Theme.good : Theme.danger } ?? Theme.muted.opacity(0.5))
                    Text("\(users) agent\(users == 1 ? "" : "s")").font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            .padding(12)
            .background(selected ? Theme.accent.opacity(0.14) : Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.accent.opacity(0.6) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CandidateRow: View {
    @EnvironmentObject var model: Model
    let item: Candidate
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.alias).font(.system(.callout, design: .monospaced))
                Text(item.username.isEmpty ? item.source : "\(item.source) · \(item.username)").font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Button("Approve") { model.approve(item) }.buttonStyle(GoldButton())
        }
        .padding(12)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4])))
    }
}

struct CredentialDetail: View {
    @EnvironmentObject var model: Model
    let entry: VaultEntry
    @State private var confirmRevoke = false

    var body: some View {
        let meta = model.meta(entry.alias)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "key.fill").font(.system(size: 22)).foregroundStyle(Theme.onAccent)
                        .frame(width: 52, height: 52)
                        .background(LinearGradient(colors: [Theme.accentGlow, Theme.accent], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.alias).font(.system(size: 24, weight: .bold, design: .monospaced))
                        Text("\(entry.username.isEmpty ? "No username" : "User \(entry.username)") · \(ago(meta.lastUsed))")
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.top, 40)

                Card(title: "Note for AIs", subtitle: "Shown in `harbor list`, so agents pick the right credential without asking you.") {
                    TextField("e.g. sudo on build-server (ssh build) as admin", text: model.binding(alias: entry.alias, \.note), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }

                Card(title: "Agents that can use it", subtitle: "Unticked agents get “not allowed” from harbor.") {
                    ForEach(model.config.agents) { agent in
                        Toggle(isOn: model.allows(agent.id, entry.alias)) {
                            HStack { Avatar(name: agent.name, size: 22); Text(agent.name) }
                        }
                        .toggleStyle(RightSwitch())
                    }
                }

                Card(title: "Health check", subtitle: "A shell command run as you, daily and on demand. The password is on stdin, in $HARBOR_PASSWORD (and $HARBOR_USER), and answers ssh/sudo -A prompts.") {
                    TextField(#"e.g. ssh build 'sudo -S -p "" true'"#, text: model.binding(alias: entry.alias, \.test))
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 10) {
                        Button { model.runTest(entry.alias) } label: {
                            if model.testing.contains(entry.alias) { ProgressView().controlSize(.small) } else { Label("Run test", systemImage: "play.fill") }
                        }
                        .buttonStyle(GoldButton())
                        .disabled(meta.test.isEmpty || model.testing.contains(entry.alias))
                        if let health = meta.health {
                            Dot(color: health.ok ? Theme.good : Theme.danger)
                            Text("\(health.ok ? "Passed" : "Failed") \(health.date.formatted(.relative(presentation: .named)))")
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    if let output = meta.health?.output, !output.isEmpty {
                        Text(output).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                            .lineLimit(6).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                Card(title: "Revoke", subtitle: "Removes Harbor's copy. Every agent loses access immediately; the original Keychain item stays.") {
                    Button("Revoke \(entry.alias)") { confirmRevoke = true }.buttonStyle(GoldButton(destructive: true))
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .confirmationDialog("Revoke \(entry.alias) for all agents?", isPresented: $confirmRevoke) {
            Button("Revoke", role: .destructive) { model.revoke(entry.alias) }
        }
    }
}

struct AddCredentialSheet: View {
    @EnvironmentObject var model: Model
    @State private var alias = "AI-"
    @State private var username = ""
    @State private var note = ""
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a credential").font(.title2.bold())
            Text("Stored in your login keychain, readable only by Credential Harbor. AIs refer to it as {{\(alias)}}.")
                .font(.callout).foregroundStyle(Theme.muted)
            Form {
                TextField("Name", text: $alias, prompt: Text("AI-Server"))
                TextField("Username", text: $username, prompt: Text("optional"))
                TextField("Note for AIs", text: $note, prompt: Text("what it's for, which host"))
                SecureField("Secret", text: $secret, prompt: Text("password, API key or token"))
            }
            HStack {
                Spacer()
                Button("Cancel") { model.addingCredential = false }
                Button("Save") {
                    model.add(alias: alias, username: username, note: note, secret: secret)
                    model.addingCredential = false
                }
                .buttonStyle(GoldButton())
                .keyboardShortcut(.defaultAction)
                .disabled(!Vault.isValidAlias(alias) || secret.isEmpty)
            }
        }
        .padding(24).frame(width: 460)
    }
}

// MARK: - Agents

struct Avatar: View {
    let name: String
    var size: CGFloat = 34
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.onAccent)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Theme.accentGlow, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
    }
}

struct AgentsView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PageHeader(title: "Agents", subtitle: "Who can call harbor, and with what") {
                    Button { model.addAgent() } label: { Label("Add", systemImage: "plus") }.buttonStyle(GoldButton())
                }
                ScrollView {
                    VStack(spacing: 8) { ForEach(model.config.agents) { agent in AgentCard(agent: agent) } }
                        .padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
            .frame(width: 340)
            Rectangle().fill(Theme.line).frame(width: 1)
            if let agent = model.agent(model.selectedAgent) {
                AgentDetail(agentID: agent.id).id(agent.id)
            } else {
                Placeholder(icon: "person.2", text: "Select an agent.")
            }
        }
    }
}

struct AgentCard: View {
    @EnvironmentObject var model: Model
    let agent: Agent

    var body: some View {
        let selected = model.selectedAgent == agent.id
        let (status, color): (String, Color) =
            agent.keyHash == nil ? ("No key yet", Theme.muted)
            : agent.paused ? ("Paused", Theme.danger)
            : ("\(agent.allowed.count) credential\(agent.allowed.count == 1 ? "" : "s")", Theme.good)
        Button { model.selectedAgent = agent.id } label: {
            HStack(spacing: 12) {
                Avatar(name: agent.name)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name).font(.body.weight(.semibold))
                    Text("\(agent.kind.rawValue) · \(ago(agent.lastUsed))").font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                HStack(spacing: 6) { Dot(color: color); Text(status).font(.caption).foregroundStyle(Theme.muted) }
            }
            .padding(12)
            .background(selected ? Theme.accent.opacity(0.14) : Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.accent.opacity(0.6) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AgentDetail: View {
    @EnvironmentObject var model: Model
    let agentID: UUID
    @State private var confirmRemove = false

    var body: some View {
        let agent = model.agent(agentID)!
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Avatar(name: agent.name, size: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Name", text: model.binding(agent: agentID, \.name))
                            .font(.system(size: 22, weight: .bold, design: .rounded)).textFieldStyle(.plain)
                        Picker("", selection: model.binding(agent: agentID, \.kind)) {
                            ForEach(AgentKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    Spacer()
                    Toggle("Paused", isOn: model.binding(agent: agentID, \.paused)).toggleStyle(.switch)
                }
                .padding(.top, 40)

                Card(title: "Agent key", subtitle: "Goes in the agent's environment as HARBOR_AGENT_KEY, never in a prompt or memory. Harbor keeps only a hash, so a lost key is replaced, not shown again.") {
                    HStack(spacing: 10) {
                        Image(systemName: agent.keyHash == nil ? "key.slash" : "checkmark.seal.fill")
                            .foregroundStyle(agent.keyHash == nil ? Theme.muted : Theme.good)
                        Text(agent.keyCreated.map { "Key created \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No key yet. This agent can't use harbor.")
                        Spacer()
                        Button(agent.keyHash == nil ? "Generate key" : "Replace key") { model.generateKey(agentID) }.buttonStyle(GoldButton())
                    }
                }

                Card(title: "Credentials it can use", subtitle: model.approved.isEmpty ? "No credentials approved yet. Add them under Credentials." : nil) {
                    ForEach(model.approved) { entry in
                        Toggle(isOn: model.allows(agentID, entry.alias)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.alias).font(.system(.body, design: .monospaced))
                                if !model.meta(entry.alias).note.isEmpty { Text(model.meta(entry.alias).note).font(.caption).foregroundStyle(Theme.muted) }
                            }
                        }
                        .toggleStyle(RightSwitch())
                    }
                }

                Card(title: "Recent activity") {
                    let mine = model.events.filter { $0.agent == agent.name }.suffix(5).reversed()
                    if mine.isEmpty { Text("Nothing yet.").foregroundStyle(Theme.muted) }
                    ForEach(Array(mine)) { EventRow(event: $0, compact: true) }
                }

                Card(title: "Remove agent", subtitle: "Its key stops working immediately.") {
                    Button("Remove \(agent.name)") { confirmRemove = true }.buttonStyle(GoldButton(destructive: true))
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .confirmationDialog("Remove \(agent.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.removeAgent(agentID) }
        }
    }
}

struct KeySheet: View {
    @EnvironmentObject var model: Model

    var body: some View {
        if let (agent, key) = model.revealedKey {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Avatar(name: agent.name, size: 40)
                    VStack(alignment: .leading) {
                        Text("Key for \(agent.name)").font(.title2.bold())
                        Text("Copy it now. Harbor won't show it again.").foregroundStyle(Theme.muted)
                    }
                }
                Text(key).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                Text("Setup (\(agent.kind.rawValue))").font(.headline)
                Text(agent.kind.setup(key: key)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                Text("Then add the AI instructions to its system prompt, AGENTS.md or CLAUDE.md. They contain no key.")
                    .font(.caption).foregroundStyle(Theme.muted)
                HStack {
                    Button("Copy key") { model.copy(key, "Copied \(agent.name)'s key.") }
                    Button("Copy setup") { model.copy(agent.kind.setup(key: key), "Copied setup for \(agent.name).") }
                    Button("Copy AI instructions") { model.copy(aiInstructions, "Copied AI instructions.") }
                    Spacer()
                    Button("Done") { model.revealedKey = nil }.buttonStyle(GoldButton()).keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 560)
        }
    }
}

// MARK: - Activity

struct EventRow: View {
    let event: Event
    var compact = false
    var body: some View {
        let color = event.ok == nil ? Theme.accent : event.ok! ? Theme.good : Theme.danger
        HStack(alignment: .top, spacing: 10) {
            Dot(color: color).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !compact { Text(event.agent).fontWeight(.semibold) }
                    ForEach(event.aliases, id: \.self) { alias in
                        Text(alias).font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.15), in: Capsule()).foregroundStyle(Theme.accentGlow)
                    }
                    if event.user != NSUserName() && event.user != "?" { Text("as \(event.user)").font(.caption).foregroundStyle(Theme.muted) }
                    Spacer()
                    Text(event.date.formatted(date: compact ? .omitted : .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.muted)
                }
                if !event.command.isEmpty {
                    Text("$ " + event.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text.opacity(0.8)).lineLimit(2)
                }
                Text(event.result).font(.caption).foregroundStyle(event.ok == false ? Theme.danger.opacity(0.95) : Theme.muted)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ActivityView: View {
    @EnvironmentObject var model: Model
    @State private var filter = "All agents"

    var body: some View {
        let names = ["All agents"] + model.config.agents.map(\.name) + ["Unknown"]
        let shown = model.events.reversed().filter { filter == "All agents" || $0.agent == filter }
        VStack(spacing: 0) {
            PageHeader(title: "Activity", subtitle: "Every harbor call, allowed or denied") {
                HStack {
                    Picker("", selection: $filter) { ForEach(names, id: \.self) { Text($0) } }.labelsHidden().frame(width: 150)
                    Button { model.exportLog() } label: { Label("Export", systemImage: "square.and.arrow.up") }.buttonStyle(GoldButton())
                }
            }
            if shown.isEmpty {
                Placeholder(icon: "waveform.path.ecg", text: "No activity yet.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown)) { event in
                            EventRow(event: event).padding(.horizontal, 16)
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
    }
}

// MARK: - Settings

struct ThemeSwatch: View {
    let name: ThemeName
    @Binding var selected: ThemeName

    var body: some View {
        let palette = name.palette
        let isOn = selected == name
        Button { selected = name } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [palette.top, palette.bg2, palette.bg], startPoint: .top, endPoint: .bottom))
                    HStack(spacing: 4) {
                        Circle().fill(palette.accent).frame(width: 12, height: 12)
                        RoundedRectangle(cornerRadius: 3).fill(palette.card).frame(width: 26, height: 12)
                    }
                    .padding(8)
                }
                .frame(width: 96, height: 60)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isOn ? Theme.accent : Theme.line, lineWidth: isOn ? 2 : 1))
                Text(name.rawValue).font(.caption.weight(isOn ? .semibold : .regular))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let settings = Binding(get: { model.config.settings }, set: { value in model.update { $0.settings = value } })
        VStack(spacing: 0) {
            PageHeader(title: "Settings", subtitle: "Credential Harbor 1.2") { EmptyView() }
            ScrollView {
                VStack(spacing: 14) {
                    Card(title: "Theme") {
                        HStack(spacing: 12) {
                            ForEach(ThemeName.allCases) { name in ThemeSwatch(name: name, selected: settings.theme) }
                        }
                    }
                    Card(title: "Pause all", subtitle: "Every harbor call is denied until you switch this back. Nothing is revoked.") {
                        Toggle(isOn: settings.pauseAll) {
                            Text(model.config.settings.pauseAll ? "Paused: all agents are blocked" : "Active")
                                .foregroundStyle(model.config.settings.pauseAll ? Theme.danger : Theme.text)
                        }
                        .toggleStyle(RightSwitch())
                    }
                    Card(title: "Notifications") {
                        Picker("Notify me", selection: settings.notify) {
                            ForEach(NotifyLevel.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Card(title: "Launch at login", subtitle: "harbor only works while the app is running, so keep it on for overnight work.") {
                        Toggle("Open Credential Harbor at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                            .toggleStyle(RightSwitch())
                    }
                    Card(title: "Activity log") {
                        HStack {
                            Picker("Keep activity for", selection: settings.retentionDays) {
                                ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) days").tag($0) }
                            }
                            .frame(width: 260)
                            Spacer()
                            Button { model.exportLog() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        }
                    }
                    Card(title: "Set up AIs", subtitle: "Each agent needs its key (Agents → Generate key) plus these instructions in its prompt or AGENTS.md. The instructions are the same for every AI and contain no secrets.") {
                        HStack {
                            Button("Copy AI instructions") { model.copy(aiInstructions, "Copied AI instructions.") }.buttonStyle(GoldButton())
                            Spacer()
                        }
                        Text("CLI \(Wire.cliPath)\nSocket \(Wire.socketPath)\nOther local users (e.g. a service account): add /Users/Shared/CredentialHarbor/bin to PATH.")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                        if let error = model.brokerError { Text(error).foregroundStyle(Theme.danger) }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
    }
}
