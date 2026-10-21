import Foundation

public enum TerminalPastePolicy {
    public static let maximumBytes = 1_048_576
    public static func valid(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= maximumBytes && !text.unicodeScalars.contains { scalar in
            (scalar.value < 32 && ![9, 10, 13].contains(scalar.value)) || (127...159).contains(scalar.value)
        }
    }
    public static func needsReview(_ text: String) -> Bool { text.contains("\n") || text.contains("\r") || text.utf8.count > 1024 }
}
