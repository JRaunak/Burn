import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                    Text(model.scanning ? "Indexing…" : usd(model.today.cost) + plus(model.today))
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("This month").font(.caption).foregroundStyle(.secondary)
                    Text(model.scanning ? "…" : usd(model.month.cost) + plus(model.month)).font(.title3).monospacedDigit()
                }
            }

            Picker("Source", selection: $model.source) {
                ForEach(Sources.all, id: \.self) { Text(Sources.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if model.scanning {
                Text("Reading your Claude Code transcripts for the first time. Totals fill in as it goes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if model.today.cost == 0 && model.todayProjects.isEmpty {
                Text("No usage today.").foregroundStyle(.secondary)
            } else {
                SliceList(title: "Projects", slices: model.todayProjects)
                SliceList(title: "Models", slices: model.todayModels)
                SliceList(title: "Agents", slices: model.todayAgents)
            }

            if model.month.unpricedTokens > 0 {
                Label {
                    Text("\(tokens(model.today.unpricedTokens)) tokens today and \(tokens(model.month.unpricedTokens)) this month have no price (\(model.month.unpricedModels.joined(separator: ", "))). Add them to pricing.json.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
            }
            ForEach(model.errors, id: \.self) { e in
                Label(e, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            Text(model.caveat).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Button("History") { close(); Windows.shared.show("history") }
                Button("Settings") { close(); Windows.shared.show("settings") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private func plus(_ s: Summary) -> String { s.unpricedTokens > 0 ? "+" : "" }

struct SliceList: View {
    let title: String
    let slices: [Slice]

    var body: some View {
        if !slices.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ForEach(slices) { s in
                    HStack {
                        Text(s.name.isEmpty ? "unknown" : s.name).lineLimit(1)
                        Spacer()
                        Text(usd(s.cost)).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}
