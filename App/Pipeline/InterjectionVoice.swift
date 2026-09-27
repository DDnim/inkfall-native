import AVFoundation
import InkfallCore

/// 试做：把纠正念出来（本地 AVSpeechSynthesizer，不联网、不要 key）。
///
/// ⚠️ 长录音还开着麦克风：念的这句会被录进去、转写、粘到文档里。所以调用方在
/// `onStart` 先把之前的话切成一段送走，念的期间不喂切段器，`onFinish` 把这段时间
/// 录到的音频整段扔掉。戴耳机就没这个问题，但不能指望。
@MainActor
final class InterjectionVoice: NSObject, AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?

    private(set) var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, onStart: () -> Void, onFinish: @escaping () -> Void) {
        if isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: InterjectionAPI.speechLanguage(for: text))
        isSpeaking = true
        self.onFinish = onFinish
        onStart()
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    private func finished() {
        guard isSpeaking else { return }
        isSpeaking = false
        let done = onFinish
        onFinish = nil
        done?()
    }
}
