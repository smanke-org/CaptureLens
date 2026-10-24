import Observation

/// Whether a newer release is waiting, as found by the silent check at launch.
///
/// The launch check deliberately stops here rather than prompting. Installing an update
/// is the user's decision, and a menu bar app has no reliable way to ask for one from a
/// background task — so the answer is to not ask from there at all, and let the menu
/// carry the offer until it is acted on.
@Observable
@MainActor
final class UpdateAvailability {
    static let shared = UpdateAvailability()
    var pending: String?
    private init() {}
}
