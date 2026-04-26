import SwiftUI
import SwiftData
import Charts

nonisolated enum ProgressTrendTimeframe: String, CaseIterable, Identifiable, Hashable {
    case month
    case days90
    case days180
    case year
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .month: "Month"
        case .days90: "90 Days"
        case .days180: "180 Days"
        case .year: "Year"
        case .custom: "Custom"
        }
    }

    /// `nil` for `.custom`, where the range comes from explicit start/end pickers.
    var daysBack: Int? {
        switch self {
        case .month: 30
        case .days90: 90
        case .days180: 180
        case .year: 365
        case .custom: nil
        }
    }
}

struct ProgressTrendView: View {

    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: [SortDescriptor(\WeightEntry.timestamp, order: .forward)]) private var weightEntries: [WeightEntry]

    @State private var timeframe: ProgressTrendTimeframe = .days90
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: .now)) ?? .now
    @State private var customEnd: Date = Calendar.current.startOfDay(for: .now)
    @State private var showSettings = false

    private var preferredUnit: WeightUnit {
        profiles.first?.weightUnit ?? .pounds
    }

    private var range: (start: Date, end: Date) {
        let calendar = Calendar.current
        if timeframe == .custom {
            let s = calendar.startOfDay(for: customStart)
            let e = calendar.startOfDay(for: customEnd)
            return s <= e ? (s, e) : (e, s)
        }
        let end = calendar.startOfDay(for: .now)
        let days = timeframe.daysBack ?? 30
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        return (start, end)
    }

    private var rangeDayCount: Int {
        max(1, (Calendar.current.dateComponents([.day], from: range.start, to: range.end).day ?? 0) + 1)
    }

    private struct WeightPoint: Identifiable, Hashable {
        let id: String
        let date: Date
        let weight: Double
    }

    private var weightPoints: [WeightPoint] {
        let calendar = Calendar.current
        let (start, end) = range
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: end) ?? end
        return weightEntries
            .filter { $0.timestamp >= start && $0.timestamp < rangeEnd }
            .sorted { $0.timestamp < $1.timestamp }
            .map {
                WeightPoint(
                    id: $0.id.uuidString,
                    date: $0.timestamp,
                    weight: $0.weight(in: preferredUnit)
                )
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    timeframePicker
                    if timeframe == .custom {
                        customRangeEditor
                    }
                    weightChartCard
                    summaryCard
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Progress")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var timeframePicker: some View {
        HStack {
            Picker("Timeframe", selection: $timeframe) {
                ForEach(ProgressTrendTimeframe.allCases) { tf in
                    Text(tf.displayName).tag(tf)
                }
            }
            .pickerStyle(.menu)
            Spacer()
        }
    }

    private var customRangeEditor: some View {
        HStack(spacing: 12) {
            DatePicker("Start", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                .labelsHidden()
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            DatePicker("End", selection: $customEnd, in: customStart...Date(), displayedComponents: .date)
                .labelsHidden()
            Spacer()
        }
    }

    private var weightChartCard: some View {
        let points = weightPoints
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weight (\(preferredUnit.suffix))").font(.headline)
                Spacer()
            }
            if points.isEmpty {
                Text("No weight entries in this range. Log a weight from the My Plan tab to see your trend here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Weight", point.weight)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.accentColor)
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Weight", point.weight)
                        )
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(height: 240)
                .chartXScale(domain: range.start...range.end)
                .chartXAxis { weightXAxis }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(String(format: "%.1f", v)).font(.caption2.monospacedDigit())
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    @AxisContentBuilder
    private var weightXAxis: some AxisContent {
        let days = rangeDayCount
        if days <= 14 {
            AxisMarks(values: .stride(by: .day, count: max(1, days / 4))) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        } else if days <= 60 {
            AxisMarks(values: .stride(by: .day, count: max(1, days / 6))) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        } else if days <= 200 {
            AxisMarks(values: .stride(by: .month, count: 1)) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        } else {
            AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        let points = weightPoints
        if let first = points.first, let last = points.last {
            let delta = last.weight - first.weight
            HStack(spacing: 12) {
                summaryTile(
                    title: "Latest",
                    value: String(format: "%.1f", last.weight),
                    unit: preferredUnit.suffix
                )
                if first.id != last.id {
                    summaryTile(
                        title: "Change",
                        value: (delta > 0 ? "+" : "") + String(format: "%.1f", delta),
                        unit: preferredUnit.suffix
                    )
                }
            }
        }
    }

    private func summaryTile(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }
}
