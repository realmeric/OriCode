import Foundation

/// Claude Code compacts a session only near its 1M window, and every call before then reads all of
/// it again. Past this many tokens of context the engine compacts a Claude thread between turns.
enum AutoCompact {
    static let key = "compactAt"
    static let standard = 200_000
    /// Off, then the thresholds Settings offers.
    static let choices = [0, 200_000, 400_000, 600_000]

    static var threshold: Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? standard
    }

    static func name(_ tokens: Int) -> String {
        tokens == 0 ? "Off" : tokens.formatted(.number.notation(.compactName))
    }
}
