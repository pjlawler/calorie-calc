import Foundation

enum CalorieFormatter {
    static func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }

    static func signed(_ value: Double) -> String {
        let rounded = value.rounded()
        let sign = rounded > 0 ? "+" : ""
        return "\(sign)\(whole(rounded))"
    }

    static func macro(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func weight(_ value: Double, unit: WeightUnit) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit.suffix)"
    }
}

enum DurationFormatter {
    static func minutesAndSeconds(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m > 0 && s > 0 { return "\(m)m \(s)s" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }
}
