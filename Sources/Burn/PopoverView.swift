import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                    Text(usd(model.today.cost)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("This month").font(.caption).foregroundStyle(.secondary)
                    Text(usd(model.month.cost)).font(.title3).monospacedDigit()
                }
            }

            Picker("Source", selection: $model.source) {
                ForEach(Sources.all, id: \.self) { Text(Sources.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if model.today.cost == 0 && model.todayProjects.isEmpty {
                Text("No usage today.").foregroundStyle(.secondary)
            } else {
                SliceList(title: "Projects", slices: model.todayProjects)
                SliceList(title: "Models", slices: model.todayModels)
                SliceList(title: "Agents", slices: model.todayAgents)
            }

            if model.today.unpricedTokens > 0 {
                Label("\(tokens(model.today.unpricedTokens)) tokens today have no price (\(model.today.unpricedModels.joined(separator: ", "))). Add them to pricing.json.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(model.errors, id: \.self) { e in
                Label(e, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            Text(model.activeSource.caveat).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Button("History") { bringForward(); openWindow(id: "history") }
                Button("Settings") { bringForward(); openWindow(id: "settings") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }
}

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
