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

final class Note: ObservableObject {
    @Published var text = ""
    @Published var login = LoginItem.enabled
}
