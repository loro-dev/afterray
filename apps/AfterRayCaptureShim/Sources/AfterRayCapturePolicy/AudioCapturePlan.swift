package struct AudioCapturePlan: Equatable, Sendable {
    package let capturesSystemAudio: Bool
    package let capturesMicrophone: Bool

    /// System audio rides the Screen Recording grant; only the microphone
    /// stream needs its own TCC consent. Adding the microphone output without
    /// authorization makes `SCStream.startCapture` fail wholesale, taking the
    /// screen down with it — so a declined microphone degrades to system audio
    /// instead of blocking capture.
    package init(recordsAudio: Bool, hasMicrophoneInput: Bool, microphoneAuthorized: Bool) {
        capturesSystemAudio = recordsAudio
        capturesMicrophone = recordsAudio && hasMicrophoneInput && microphoneAuthorized
    }
}
