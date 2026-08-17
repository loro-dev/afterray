package struct AudioCapturePlan: Equatable, Sendable {
    package let capturesSystemAudio: Bool
    package let capturesMicrophone: Bool

    package init(recordsAudio: Bool, hasMicrophoneInput: Bool) {
        capturesSystemAudio = recordsAudio
        capturesMicrophone = recordsAudio && hasMicrophoneInput
    }
}
