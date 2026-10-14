/// The user-selectable height behavior for the menu-bar popover.
///
/// Persist the semantic raw value rather than a point measurement so future
/// layout changes do not invalidate an existing preference.
public enum MenuPopoverHeightMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case thirtyPercentTaller
    case showAll

    public static let `default`: Self = .showAll

    public var id: String { rawValue }
}
