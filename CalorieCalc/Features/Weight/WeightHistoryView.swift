import SwiftUI
import Charts

struct WeightHistoryView: View {

    let entries: [WeightEntry]
    let displayUnit: WeightUnit

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("No weight logged", systemImage: "scalemass", description: Text("Log a weight below to see your trend."))
        } else {
            Chart {
                ForEach(entries.reversed()) { entry in
                    LineMark(
                        x: .value("Date", entry.timestamp),
                        y: .value("Weight", entry.weight(in: displayUnit))
                    )
                    .interpolationMethod(.monotone)
                    .symbol(.circle)
                    .foregroundStyle(.tint)
                }
            }
            .chartYAxisLabel(displayUnit.suffix)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4))
            }
        }
    }
}
