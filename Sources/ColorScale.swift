import SwiftUI

enum ColorScale {
    /// Returns a green intensity level (0-4) based on quartile distribution.
    /// 0 = no contributions (gray), 1-4 = light to dark green.
    static func level(for value: Int, allValues: [Int]) -> Int {
        guard value > 0 else { return 0 }

        let nonZero = allValues.filter { $0 > 0 }.sorted()
        guard !nonZero.isEmpty else { return 0 }

        let q1 = percentile(nonZero, 0.25)
        let q2 = percentile(nonZero, 0.50)
        let q3 = percentile(nonZero, 0.75)

        if value <= q1 { return 1 }
        if value <= q2 { return 2 }
        if value <= q3 { return 3 }
        return 4
    }

    static func color(for level: Int) -> Color {
        switch level {
        case 0: return Color(.sRGB, red: 0.22, green: 0.22, blue: 0.24, opacity: 1) // empty gray
        case 1: return Color(.sRGB, red: 0.0, green: 0.43, blue: 0.18, opacity: 1)  // light green
        case 2: return Color(.sRGB, red: 0.0, green: 0.55, blue: 0.22, opacity: 1)
        case 3: return Color(.sRGB, red: 0.15, green: 0.68, blue: 0.28, opacity: 1)
        case 4: return Color(.sRGB, red: 0.22, green: 0.84, blue: 0.35, opacity: 1) // bright green
        default: return Color.gray
        }
    }

    private static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        let index = p * Double(sorted.count - 1)
        let lower = Int(index)
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = index - Double(lower)
        return Int(Double(sorted[lower]) + fraction * Double(sorted[upper] - sorted[lower]))
    }
}
