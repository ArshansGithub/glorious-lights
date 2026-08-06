import Foundation

/// Where the visualizer gets its audio.
///
/// The analysis and render pipeline is source-agnostic — both of these produce
/// mono `Float` windows and everything downstream is identical — so this only
/// decides which capture object is built and which permission is involved.
public enum AudioSource: String, CaseIterable, Sendable {
    /// The microphone. Picks up the room, so it responds to speakers, but also
    /// to typing and conversation.
    case microphone
    /// The system output mix, tapped before it reaches the speakers. What is
    /// actually playing, and silent when nothing is.
    case systemAudio

    public var displayName: String {
        switch self {
        case .microphone:  return "Microphone"
        case .systemAudio: return "System Audio"
        }
    }

    /// What macOS calls the permission this source needs, for menu copy.
    public var permissionName: String {
        switch self {
        case .microphone:  return "Microphone"
        case .systemAudio: return "Audio Recording"
        }
    }
}

/// Whether a source can be used, without attempting to start it.
public enum AudioSourceAuthorization: Equatable, Sendable {
    case granted
    case denied
    /// Not yet asked — starting will prompt.
    case undetermined
    /// The OS does not offer this source at all.
    case unavailable
}

/// Picks the source to start with.
///
/// System audio is preferred when it is already granted, because it is what
/// someone playing music actually wants: it hears the mix rather than the room,
/// so it does not react to typing and does not need speakers turned up. Anything
/// less than granted falls back to the microphone rather than provoking a
/// permission prompt the user did not ask for — the prompt should follow a
/// deliberate choice in the picker, not appear because the app launched.
public func preferredAudioSource(
    systemAudio: AudioSourceAuthorization,
    microphone: AudioSourceAuthorization
) -> AudioSource {
    if systemAudio == .granted { return .systemAudio }
    if microphone == .granted { return .microphone }
    // Neither is granted: offer the one that can still be asked for, preferring
    // the microphone because its prompt is the one users recognise.
    if microphone == .undetermined { return .microphone }
    if systemAudio == .undetermined { return .systemAudio }
    return .microphone
}
