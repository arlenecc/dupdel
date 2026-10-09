import Foundation

public enum ByteFormatter {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// 1024 进制的可读体积，例如 "1.25 GB"。
    public static func string(_ bytes: UInt64) -> String {
        guard bytes >= 1024 else { return "\(bytes) B" }
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if value >= 100 {
            return String(format: "%.0f %@", value, units[unit])
        }
        if value >= 10 {
            return String(format: "%.1f %@", value, units[unit])
        }
        return String(format: "%.2f %@", value, units[unit])
    }

    /// 千分位计数，例如 "1,234"。
    public static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
