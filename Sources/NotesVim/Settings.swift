import Foundation

@MainActor
final class Settings {
    private let defaults = UserDefaults.standard
    var onChange: (() -> Void)?

    var isEnabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "enabled")
            onChange?()
        }
    }

    /// Notes paragraphs usually wrap over several lines, so by default `j` / `k` move by
    /// what you see rather than by paragraph.
    var verticalMovesUseScreenLines: Bool {
        get { defaults.object(forKey: "verticalMovesUseScreenLines") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "verticalMovesUseScreenLines")
            onChange?()
        }
    }
}
