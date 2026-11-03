import SwiftUI

enum ShravaTheme {
    /// Deep indigo from the Shrava logo.
    static let indigo = Color(red: 0.14, green: 0.08, blue: 0.36)
    /// Lifted purple for interactive accents.
    static let purple = Color(red: 0.42, green: 0.28, blue: 0.92)
    /// Coral / red accent from the logo highlight.
    static let coral = Color(red: 0.97, green: 0.22, blue: 0.20)
    static let magenta = Color(red: 0.72, green: 0.22, blue: 0.78)

    static let brandGradient = LinearGradient(
        colors: [purple, magenta, coral],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let softBackground = LinearGradient(
        colors: [
            Color(red: 0.07, green: 0.05, blue: 0.16),
            Color(red: 0.12, green: 0.08, blue: 0.28),
            Color(red: 0.18, green: 0.06, blue: 0.18)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let tagline = "Every Conversation, Captured"

    static func title(from text: String, limit: Int = 48) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled capture" }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        if firstLine.count <= limit { return firstLine }
        let idx = firstLine.index(firstLine.startIndex, offsetBy: limit)
        return String(firstLine[..<idx]).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension View {
    /// Apply Liquid Glass when available / transparency allowed; otherwise material fallback.
    @ViewBuilder
    func shravaGlass(
        _ glass: Glass = .regular,
        in shape: some Shape = RoundedRectangle(cornerRadius: 20, style: .continuous),
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            let g = interactive ? glass.interactive() : glass
            self.glassEffect(g, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
