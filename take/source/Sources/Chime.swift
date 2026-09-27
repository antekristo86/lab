// take. Short synthesized feedback tones for voice commands. Made with Claude Code.
import AVFoundation

/// Soft sine tones with a fast attack and an exponential decay, a touch of octave for a glassy edge.
/// Played only while nothing is being written, so they never end up in a take.
final class Chime {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        try? engine.start()
    }

    /// Countdown 3, 2, 1.
    func tick() { play([(987.77, 0.09)], volume: 0.22) }
    /// Recording starts after this one has faded.
    func go() { play([(1318.51, 0.18)], volume: 0.26) }
    /// Take stopped and kept.
    func end() { play([(1318.51, 0.09), (987.77, 0.16)], volume: 0.24) }
    /// Take discarded.
    func discard() { play([(587.33, 0.09), (587.33, 0.12)], volume: 0.24) }
    /// Command understood, nothing else to say.
    func ack() { play([(1174.66, 0.08)], volume: 0.2) }

    private func play(_ notes: [(freq: Double, dur: Double)], volume: Float, gap: Double = 0.07) {
        let sr = format.sampleRate
        let total = notes.reduce(0) { $0 + $1.dur + gap } + 0.05
        let frames = AVAudioFrameCount(total * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let out = buf.floatChannelData?[0] else { return }
        buf.frameLength = frames
        for i in 0..<Int(frames) { out[i] = 0 }
        var t0 = 0.0
        for n in notes {
            let start = Int(t0 * sr), len = Int(n.dur * sr)
            for i in 0..<len where start + i < Int(frames) {
                let t = Double(i) / sr
                let attack = min(1, t / 0.004)
                let decay = exp(-t / (n.dur * 0.38))
                let s = sin(2 * .pi * n.freq * t) + 0.18 * sin(2 * .pi * n.freq * 2 * t)
                out[start + i] += Float(s * attack * decay) * volume
            }
            t0 += n.dur + gap
        }
        // No output device, or it changed and the restart failed: stay silent. Older AVAudioEngine builds
        // assert when a player starts on a stopped engine.
        if !engine.isRunning { do { try engine.start() } catch { return } }
        player.scheduleBuffer(buf, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }
}
