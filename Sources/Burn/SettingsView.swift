import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("bedrock.enabled") private var bedrockOn = false
    @AppStorage("bedrock.profile") private var profile = Settings.bedrockConfig().profile
    @AppStorage("bedrock.region") private var region = Settings.bedrockConfig().region
    @AppStorage("bedrock.logGroup") private var logGroup = "/aws/bedrock/modelinvocations"
    @AppStorage("bedrock.identity") private var identity = ""
    @AppStorage("bedrock.lookbackDays") private var lookback = 7
    @AppStorage("otel.enabled") private var otelOn = false
    @AppStorage("otel.port") private var otelPort = 4318
    @StateObject private var status = Note()

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { status.login }, set: { on in
                    status.text = LoginItem.set(on) ?? ""
                    status.login = LoginItem.enabled
                }))
            }

            AlertsSection(notifier: model.notifier, changed: model.refresh, test: model.testAlert)

            Section("Pricing") {
                Text(model.pricing.url.path).font(.caption).textSelection(.enabled)
                Text("Regional premium applies to messages from regional or US-only endpoints. \(model.transcripts.endpoints.summary).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open pricing.json") { NSWorkspace.shared.open(model.pricing.url) }
                    Button("Re-read all transcripts") { model.transcripts.rescanFromZero() }
                }
            }

            Section("Bedrock invocation logs (uses the network)") {
                Toggle("Enabled", isOn: Binding(get: { bedrockOn }, set: { model.setBedrock($0) }))
                TextField("AWS profile", text: $profile)
                TextField("Region", text: $region)
                TextField("Log group", text: $logGroup)
                HStack {
                    TextField("Identity contains", text: $identity)
                    Button("Detect") { detect() }
                }
                Stepper("First sync looks back \(lookback) days", value: $lookback, in: 1...90)
                HStack {
                    Button("Sync now") { model.bedrock.syncNow() }.disabled(!bedrockOn)
                    if let d = model.bedrock.lastSync { Text("Last sync \(d.formatted(date: .omitted, time: .shortened))").font(.caption) }
                }
                Text("Runs `aws logs filter-log-events` every 15 minutes, filtered to your identity. Only token counts are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Claude Code telemetry (localhost only)") {
                Toggle("Listen on 127.0.0.1:\(otelPort)", isOn: Binding(get: { otelOn }, set: { model.setOTel($0) }))
                Text("Add to the \"env\" object in ~/.claude/settings.json yourself:\n\"CLAUDE_CODE_ENABLE_TELEMETRY\": \"1\",\n\"OTEL_LOGS_EXPORTER\": \"otlp\",\n\"OTEL_EXPORTER_OTLP_PROTOCOL\": \"http/json\",\n\"OTEL_EXPORTER_OTLP_ENDPOINT\": \"http://127.0.0.1:\(otelPort)\"")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }

            if !status.text.isEmpty { Text(status.text).font(.caption) }
        }
        .formStyle(.grouped)
        // A grouped Form scrolls, so it has no height of its own; without this the window opens empty.
        .frame(width: 540, height: 680)
        .padding()
    }

    private func detect() {
        let p = profile, r = region
        DispatchQueue.global().async {
            let result = BedrockLogSource.callerIdentity(profile: p, region: r)
            DispatchQueue.main.async {
                switch result {
                case .success(let arn):
                    identity = arn.split(separator: "/").last.map(String.init) ?? arn
                    status.text = "Using \(identity)"
                case .failure(let e):
                    status.text = "\(e)"
                }
            }
        }
    }
}

struct AlertsSection: View {
    @ObservedObject var notifier: Notifier
    let changed: () -> Void
    let test: () -> Void
    @AppStorage("alert.sound") private var sound = Settings.defaultSound
    @AppStorage("alert.day") private var daily: Double?
    @AppStorage("alert.week") private var weekly: Double?
    @AppStorage("alert.month") private var monthly: Double?
    @AppStorage("alert.hideWhenSharing") private var hideWhenSharing = false

    var body: some View {
        Section("Alerts") {
            AmountField(label: "Daily (USD)", amount: amount($daily))
            AmountField(label: "Weekly (USD)", amount: amount($weekly))
            AmountField(label: "Monthly (USD)", amount: amount($monthly))
            Picker("Sound", selection: Binding(get: { sound }, set: { sound = $0; NSSound(named: $0)?.play() })) {
                Text("None").tag("")
                ForEach(Settings.systemSounds, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                switch notifier.status {
                case .denied?:
                    Text("Notifications are turned off for Burn.")
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                case .authorized?, .provisional?:
                    Text("Notifications allowed.")
                default:
                    Text("Notifications not requested yet.")
                }
                Spacer()
                Button("Send test notification", action: test)
            }
            Toggle("Hide banner when sharing the screen", isOn: $hideWhenSharing)
            if !notifier.error.isEmpty { Text(notifier.error).font(.caption).foregroundStyle(.red) }
            Text("Watches the selected source. Each alert fires once per period; changing the amount re-arms it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: notifier.refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in notifier.refreshStatus() }
    }

    private func amount(_ stored: Binding<Double?>) -> Binding<Double?> {
        Binding(get: { stored.wrappedValue }, set: {
            guard $0 != stored.wrappedValue else { return }
            stored.wrappedValue = $0
            if $0 != nil { notifier.authorize() }
            changed()
        })
    }
}

/// Saves on Return or focus loss only; a value TextField saves each keystroke, so typing 100 fired a $1 alert.
private struct AmountField: View {
    let label: String
    @Binding var amount: Double?
    @StateObject private var draft = Draft()
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $draft.text, prompt: Text("Off"))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onAppear(perform: show)
    }

    private func commit() {
        amount = try? Double(draft.text, format: .number)
        show()
    }

    private func show() { draft.text = amount?.formatted(.number) ?? "" }
}

private final class Draft: ObservableObject {
    @Published var text = ""
}

final class Note: ObservableObject {
    @Published var text = ""
    @Published var login = LoginItem.enabled
}
