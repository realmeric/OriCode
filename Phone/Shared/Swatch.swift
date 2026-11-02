/// ProjectBadge's eight colours and MarkPalette's makers, as the Mac has them (App/ProjectBadge.swift,
/// App/MarkPalette.swift), for the app's screens and the notification's avatar.
enum Swatch {
    static let projects: [UInt32] = [0x6F9CF6, 0xA78BFA, 0xF07AB6, 0x3FC4BE, 0xA6CF5B, 0xD8B26E, 0xD57FEA, 0x9AA8C7]
    static let makers: [String: UInt32] = [
        "claude": 0xD97757, "copilot": 0x8534F3, "pi": 0xF09082, "antigravity": 0x3186FF,
        "deepseek": 0x4D6BFE, "openrouter": 0xC8FF00, "meta": 0x0064E0,
    ]

    static func project(_ index: Int) -> UInt32 {
        projects[index % projects.count]
    }

    /// Every other agent draws in white, as its maker's own app does on dark.
    static func agent(_ id: String) -> UInt32 {
        makers[id] ?? 0xFFFFFF
    }
}
