import Charts
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var h = HistoryModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filters
            HStack(spacing: 24) {
                stat("Total", usd(h.summary.cost))
                stat("Tokens", tokens(h.summary.tokens))
                stat("Days", "\(Set(h.daily.map(\.day)).count)")
                if h.summary.unpricedTokens > 0 {
                    stat("Unpriced tokens", tokens(h.summary.unpricedTokens)).foregroundStyle(.orange)
                }
                Spacer()
            }
            DailyChart(days: h.daily).frame(height: 220)

            Table(h.sessions) {
                TableColumn("Started") { Text($0.start, format: .dateTime.day().month().hour().minute()) }
                    .width(min: 110, ideal: 120)
                TableColumn("Project", value: \.project)
                TableColumn("Session") { s in
                    Button(String(s.id.prefix(8))) { h.filter.session = h.filter.session == s.id ? "" : s.id }
                        .buttonStyle(.link)
                }
                .width(80)
                TableColumn("Messages") { Text("\($0.messages)").monospacedDigit() }.width(70)
                TableColumn("Subagents") { Text($0.subagentShare, format: .percent.precision(.fractionLength(0))).monospacedDigit() }.width(70)
                TableColumn("Cost") { s in
                    Text(usd(s.cost) + (s.unpricedTokens > 0 ? "+" : "")).monospacedDigit()
                }
                .width(80)
            }

            Text(model.activeSource.caveat + " A \"+\" means some tokens have no price.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 600)
        .onAppear { h.filter.source = model.source; load() }
        .onChange(of: h.filter) { load() }
        .onChange(of: model.today.cost) { load() }
    }

    private var filters: some View {
        HStack {
            Picker("Source", selection: $h.filter.source) {
                ForEach(Sources.all, id: \.self) { Text(Sources.label($0)).tag($0) }
            }
            .frame(width: 230)
            DatePicker("From", selection: $h.filter.from, displayedComponents: .date)
            DatePicker("To", selection: $h.filter.to, displayedComponents: .date)
            Picker("Project", selection: $h.filter.project) {
                Text("All").tag("")
                ForEach(h.projects, id: \.self) { Text($0).tag($0) }
            }
            Picker("Model", selection: $h.filter.model) {
                Text("All").tag("")
                ForEach(h.models, id: \.self) { Text($0).tag($0) }
            }
            Picker("Agent", selection: $h.filter.agent) {
                ForEach(Filter.Agent.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if !h.filter.session.isEmpty {
                Button("Session \(h.filter.session.prefix(8)) ✕") { h.filter.session = "" }
            }
        }
        .controlSize(.small)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).monospacedDigit()
        }
    }

    private func load() { h.load(model.db) }
}

struct DailyChart: View {
    let days: [DayCost]

    var body: some View {
        Chart(days) { d in
            BarMark(x: .value("Day", d.day, unit: .day), y: .value("USD", d.cost))
                .foregroundStyle(by: .value("Model", d.model))
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { Text(usd(v.as(Double.self) ?? 0)) }
            }
        }
    }
}

/// Holds view state in an ObservableObject because the CLT SDK lacks the plugin behind SwiftUI's @State macro.
final class HistoryModel: ObservableObject {
    @Published var filter = Filter()
    @Published var summary = Summary()
    @Published var daily: [DayCost] = []
    @Published var sessions: [SessionRow] = []
    @Published var projects: [String] = []
    @Published var models: [String] = []

    func load(_ db: DB) {
        let f = filter
        DispatchQueue.global(qos: .userInitiated).async {
            let r = db.queue.sync {
                (Q.summary(db, f), Q.daily(db, f), Q.sessions(db, f),
                 Q.distinct(db, "project", source: f.source), Q.distinct(db, "model", source: f.source))
            }
            DispatchQueue.main.async {
                guard f == self.filter else { return }
                (self.summary, self.daily, self.sessions, self.projects, self.models) = r
            }
        }
    }
}
