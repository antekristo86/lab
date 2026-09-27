// take. Listening: on-device speech, script tracking, spoken commands. Made with Claude Code.
import AVFoundation
import Foundation
import NaturalLanguage
import Speech

// MARK: - Listener

/// Streams the capture audio into on-device speech recognition. Never goes online.
/// Rotates to a fresh request every ~50 s so long sessions never hit a limit or grow slow.
final class Listener {
    struct Seg {
        let text: String
        let start: Double   // absolute media time, seconds (same clock as the capture PTS)
        let end: Double
        let timed: Bool     // false while the recogniser has not assigned timestamps yet
    }

    var onResult: (([Seg], Int) -> Void)?
    var onLog: ((String) -> Void)?
    /// Listening gave up after the recogniser kept failing right away. Main queue.
    var onFail: ((String) -> Void)?

    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var starts: [Int: Double] = [:]
    private var generation = 0
    private var appended: Double = 0
    private var hints: [String] = []
    private var begunAt: CFTimeInterval = 0
    private var quickErrors = 0
    private(set) var running = false
    private(set) var locale: Locale?

    /// Apple silicon, also when this process runs as x86_64 under Rosetta.
    static let appleSilicon: Bool = {
        var v: Int32 = 0
        var n = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &n, nil, 0) == 0 && v == 1
    }()

    static func authorize(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { s in DispatchQueue.main.async { done(s == .authorized) } }
    }

    static func locale(for script: String) -> Locale {
        let r = NLLanguageRecognizer()
        r.processString(script)
        return r.dominantLanguage == .german ? Locale(identifier: "de-DE") : Locale(identifier: "en-US")
    }

    /// Starts listening. Returns a reason when on-device recognition is not available.
    func start(locale: Locale, hints: [String]) -> String? {
        stop()
        guard let r = SFSpeechRecognizer(locale: locale) else { return "No recogniser for \(locale.identifier)" }
        guard r.supportsOnDeviceRecognition else {
            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            // On Apple silicon adding the dictation language brings the on-device model. Intel is untested, so no promise there.
            return Listener.appleSilicon
                ? "Add \(name) under Keyboard, Dictation in System Settings"
                : "This Mac has no on-device dictation for \(name)."
        }
        lock.lock()
        recognizer = r
        self.locale = locale
        self.hints = Array(hints.prefix(100))
        running = true
        quickErrors = 0
        lock.unlock()
        begin()
        return nil
    }

    func stop() {
        lock.lock()
        running = false
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        lock.unlock()
    }

    private func begin() {
        lock.lock()
        guard running, let r = recognizer else { lock.unlock(); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = false
        req.taskHint = .dictation
        req.contextualStrings = hints
        generation += 1
        let gen = generation
        appended = 0
        begunAt = CACurrentMediaTime()
        request = req
        lock.unlock()

        let t = r.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.lock.lock()
                let base = self.starts[gen] ?? 0
                self.quickErrors = 0
                self.lock.unlock()
                let segs = result.bestTranscription.segments.map { s in
                    Seg(text: s.substring, start: base + s.timestamp, end: base + s.timestamp + s.duration,
                        timed: s.timestamp > 0 || s.duration > 0)
                }
                DispatchQueue.main.async { self.onResult?(segs, gen) }
                if result.isFinal { self.restartIfCurrent(gen) }
            } else if let error {
                self.onLog?("recogniser gen \(gen): \(error.localizedDescription)")
                self.failed(gen, error)
            }
        }
        lock.lock()
        if gen == generation { task = t } else { t.cancel() }
        lock.unlock()
    }

    private func restartIfCurrent(_ gen: Int, after delay: Double = 0.1) {
        lock.lock()
        let current = running && gen == generation
        lock.unlock()
        guard current else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.begin() }
    }

    /// Errors after a long request (silence at the 50 s rotation, a cancel) restart at once, as before.
    /// Errors that come back within 2 s of starting, with nothing heard in between, back off: 0.1, 0.5, 2, 5 s.
    /// The fifth in a row stops listening and reports why, instead of looping silently.
    private func failed(_ gen: Int, _ error: Error) {
        lock.lock()
        guard running && gen == generation else { lock.unlock(); return }
        if CACurrentMediaTime() - begunAt < 2 { quickErrors += 1 } else { quickErrors = 0 }
        let n = quickErrors
        let giveUp = n >= 5
        if giveUp {
            running = false
            request = nil
            task = nil
        }
        lock.unlock()
        if giveUp {
            onLog?("recogniser stopped after \(n) quick errors")
            DispatchQueue.main.async { self.onFail?(error.localizedDescription) }
            return
        }
        restartIfCurrent(gen, after: [0.1, 0.5, 2, 5][min(max(n - 1, 0), 3)])
    }

    /// Capture queue.
    func append(_ sb: CMSampleBuffer) {
        lock.lock()
        guard running, let req = request else { lock.unlock(); return }
        if starts[generation] == nil { starts[generation] = CMSampleBufferGetPresentationTimeStamp(sb).seconds }
        req.appendAudioSampleBuffer(sb)
        appended += Listener.duration(sb)
        let rotate = appended > 50
        if rotate { request = nil }
        lock.unlock()
        if rotate {
            req.endAudio()
            begin()
        }
    }

    private static func duration(_ sb: CMSampleBuffer) -> Double {
        let d = CMSampleBufferGetDuration(sb)
        if d.isValid && d.seconds > 0 { return d.seconds }
        guard let f = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee, asbd.mSampleRate > 0 else { return 0.02 }
        return Double(CMSampleBufferGetNumSamples(sb)) / asbd.mSampleRate
    }
}

// MARK: - Tracker

/// Follows a spoken performance through the script. Holds still while you improvise,
/// finds you again when you come back, even a few sentences further on.
final class Tracker {
    struct Word {
        let norm: String
        let range: NSRange
        let para: Int
    }

    private(set) var words: [Word] = []
    private(set) var length = 0
    var cursor = 0

    func load(_ script: String) {
        let ns = script as NSString
        length = ns.length
        var out: [Word] = []
        var para = 0
        var lastEnd = 0
        let re = try! NSRegularExpression(pattern: "\\S+")
        for m in re.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            if !out.isEmpty && gap.contains("\n") { para += 1 }
            lastEnd = m.range.location + m.range.length
            let n = Tracker.norm(ns.substring(with: m.range))
            if n.isEmpty { continue }
            out.append(Word(norm: n, range: m.range, para: para))
        }
        words = out
        cursor = min(cursor, words.count)
    }

    static func norm(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if min(a.count, b.count) <= 3 { return 0 }
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count), cur = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Feeds what has been heard so far. Returns true when the position moved.
    @discardableResult
    func feed(_ heard: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let tail = heard.suffix(6).map(Tracker.norm).filter { !$0.isEmpty }
        guard tail.count >= 2 else { return false }

        let lo = max(0, cursor - 12)
        let hi = min(words.count - 1, cursor + 40)
        guard lo <= hi else { return false }
        var best = (score: -Double.infinity, end: -1)

        for end in lo...hi {
            var score = 0.0
            var si = end
            for t in tail.reversed() {
                var matched = false
                for k in 0...1 where si - k >= 0 {
                    let w = words[si - k]
                    let s = Tracker.similarity(t, w.norm)
                    if s >= 0.72 {
                        score += s * (w.norm.count >= 4 ? 1 : 0.5)
                        si = si - k - 1
                        matched = true
                        break
                    }
                }
                if !matched { score -= 0.2 }
            }
            let jump = end + 1 - cursor
            if jump < -1 { score -= 0.4 + Double(-jump) * 0.05 }
            if jump > 8 { score -= Double(jump - 8) * 0.03 }
            if score > best.score { best = (score, end) }
        }

        guard best.end >= 0, best.score >= 1.6 else { return false }
        let next = best.end + 1
        if next < cursor - 1 && best.score < 2.6 { return false }
        guard next != cursor else { return false }
        cursor = next
        return true
    }

    func charIndex(_ i: Int) -> Int { i < words.count ? words[i].range.location : length }

    func paragraphStart(_ i: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        let idx = min(max(0, i), words.count - 1)
        let p = words[idx].para
        var j = idx
        while j > 0 && words[j - 1].para == p { j -= 1 }
        return j
    }

    func word(atChar c: Int) -> Int {
        words.firstIndex { $0.range.location + $0.range.length > c } ?? words.count
    }

    func upcoming(_ n: Int) -> [String] {
        guard cursor < words.count else { return [] }
        return words[cursor..<min(words.count, cursor + n)].map(\.norm)
    }

    /// Whether the script itself says this command, near `around` (or anywhere when nil).
    /// `last` is true when the occurrence being read is the very end of the script, where a spoken command
    /// is meant to be performed, like the "take end." that closes a reel.
    /// When the script says it more than once, the occurrence being read is the one whose script words before it
    /// match `before` (the words heard right before the command) best, then the one nearest `around`.
    /// A tie between the end and an earlier line counts as the earlier line: a line read as an order is worse than one missed.
    func scriptSays(_ cmd: Command, before: [String] = [], around: Int?) -> (found: Bool, last: Bool) {
        guard !words.isEmpty else { return (false, false) }
        let lo = around.map { max(0, $0 - 4) } ?? 0
        let hi = around.map { min(words.count - 1, $0 + 14) } ?? (words.count - 1)
        guard lo <= hi else { return (false, false) }
        // Higher ranks first: context, then nearness, then not the end.
        var best: (rank: (Int, Int, Int), last: Bool)?
        for i in lo...hi {
            for len in 1...3 where i + len <= words.count {
                let toks = (i..<(i + len)).map { words[$0].norm }
                guard let (c, start, n) = CommandWords.find(toks), c == cmd, start == 0, n == len else { continue }
                let last = i + len == words.count
                let rank = (context(before, endingBefore: i), -(around.map { abs(i - $0) } ?? 0), last ? 0 : 1)
                if let b = best, b.rank >= rank { continue }
                best = (rank, last)
            }
        }
        return best.map { (true, $0.last) } ?? (false, false)
    }

    /// How many of the last heard words match the script words just before `end`, in order.
    private func context(_ heard: [String], endingBefore end: Int) -> Int {
        var si = end - 1, n = 0
        for t in heard.suffix(4).reversed() where si >= 0 {
            for k in 0...1 where si - k >= 0 && Tracker.similarity(t, words[si - k].norm) >= 0.72 {
                n += 1
                si -= k + 1
                break
            }
        }
        return n
    }

    /// True when the script has consecutive words that join to exactly this (normalised, no spaces).
    /// The span may be split differently from what was heard, so spans of 1 to `maxWords` words are tried.
    func contains(joined: String, maxWords: Int) -> Bool {
        guard !joined.isEmpty, !words.isEmpty else { return false }
        for start in words.indices {
            var s = ""
            for k in 0..<maxWords where start + k < words.count {
                s += words[start + k].norm
                if s == joined { return true }
                if s.count >= joined.count { break }
            }
        }
        return false
    }
}

// MARK: - Commands

enum Command: String { case start, again, end, reset }

enum CommandWords {
    /// Spoken forms, written the way a recogniser tends to write them, joined without spaces.
    static let forms: [(Command, [String])] = [
        (.again, ["takeagain", "takeagan", "takeagen", "takeagin", "takeegen", "takenochmal", "takenochmals", "techagain", "tekagain", "takeagainst"]),
        // Not "taken": a common word on its own ("it was taken.") that stopped takes mid-script. Never seen for "take end".
        (.end, ["takeend", "takeand", "takeent", "takeende", "takeends", "techend", "tekend", "takecut", "takecat", "takeenn"]),
        (.start, ["takestart", "takestarts", "takestat", "techstart", "tekstart", "takestarted", "takestarting"]),
        (.reset, ["takereset", "takerecet", "takeresets", "techreset", "takereseat", "takeresit", "taketop", "takeanfang", "takefromthetop"]),
    ]

    /// The commands as written. They are never taken for ordinary script words. A command the script says where
    /// you are reading is still a line, not an order, unless it is the script's final words (`Tracker.scriptSays`).
    /// Every other form is a mishearing, and when the script itself has those words ("give and take and",
    /// "we take top talent") the speaker is reading, not commanding.
    static let exact: Set<String> = ["takestart", "takeagain", "takeend", "takereset", "takenochmal", "takenochmals"]

    /// A command at the very end of what was heard. Returns its kind, the index of its first word and its word count.
    static func find(_ toks: [String]) -> (Command, Int, Int)? {
        let n = toks.count
        guard n >= 1 else { return nil }
        for len in [2, 1, 3, 4] where n >= len {
            let joined = toks[(n - len)...].joined()
            guard joined.hasPrefix("ta") || joined.hasPrefix("te") else { continue }
            for (cmd, list) in forms {
                for f in list where joined == f || (f.count >= 8 && joined.count >= 7 && Tracker.similarity(joined, f) >= 0.8) {
                    return (cmd, n - len, len)
                }
            }
        }
        return nil
    }
}
