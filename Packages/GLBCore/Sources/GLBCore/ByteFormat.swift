import Foundation

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let value = Double(bytes)
        let units = ["B", "KB", "MB", "GB"]
        var size = value
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        if size >= 100 { return String(format: "%.0f %@", size, units[unit]) }
        if size >= 10 { return String(format: "%.1f %@", size, units[unit]) }
        return String(format: "%.2f %@", size, units[unit])
    }

    public static func ratio(output: Int64, input: Int64) -> String {
        guard input > 0 else { return "—" }
        return String(format: "约为原来的 %.1f%%", (Double(output) / Double(input)) * 100)
    }
}
