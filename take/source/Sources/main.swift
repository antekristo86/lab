// take. A vertical recorder with a prompter. Made with Claude Code.
import AppKit
import AVFoundation
import CoreText
import Observation
import SwiftUI

// MARK: - Theme (shadcn, zinc, dark)

extension Color {
    init(hex: UInt32, _ alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, opacity: alpha)
    }
    static let bg = Color(hex: 0x09090B)
    static let card = Color(hex: 0x0C0C0E)
    static let muted = Color(hex: 0x18181B)
    static let accent = Color(hex: 0x27272A)
    static let line = Color(hex: 0x27272A)
    static let zone = Color(hex: 0x3F3F46)
    static let fg = Color(hex: 0xFAFAFA)
    static let mutedFg = Color(hex: 0xA1A1AA)
    static let subtle = Color(hex: 0x71717A)
    static let danger = Color(hex: 0xEF4444)
    static let dangerStrong = Color(hex: 0xDC2626)
    static let ok = Color(hex: 0x22C55E)
    static let warn = Color(hex: 0xF59E0B)
}

enum W { case regular, medium, semibold }

extension Font {
    static func geist(_ size: CGFloat, _ w: W = .regular) -> Font {
        switch w {
        case .regular: return .custom("Geist-Regular", fixedSize: size)
        case .medium: return .custom("Geist-Medium", fixedSize: size)
        case .semibold: return .custom("Geist-SemiBold", fixedSize: size)
        }
    }
    static func mono(_ size: CGFloat, _ w: W = .regular) -> Font {
        .custom(w == .regular ? "GeistMono-Regular" : "GeistMono-Medium", fixedSize: size)
    }
    static let bit = Font.custom("TFCBitNeue-Regular", fixedSize: 15)
}

func registerFonts() {
    for name in ["Geist-Regular", "Geist-Medium", "Geist-SemiBold", "GeistMono-Regular", "GeistMono-Medium"] {
        if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
    if let url = Bundle.main.url(forResource: "TFCBitNeue-Regular", withExtension: "otf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

// MARK: - Defaults

enum D {
    static let d = UserDefaults.standard
    static var turns: Int { get { d.integer(forKey: "turns") } set { d.set(newValue, forKey: "turns") } }
    /// No saved key at all means first launch: show the onboarding script. A cleared script is saved as "" and stays empty.
    static var script: String {
        get { d.object(forKey: "script") == nil ? onboarding : d.string(forKey: "script") ?? "" }
        set { d.set(newValue, forKey: "script") }
    }
    static let onboarding = """
    This is your teleprompter. It follows your voice.

    Read this out loud and watch it keep up. When you go off script, it waits. When you come back, it finds you.

    Press E to write your own script.
    """
    static var speed: Double {
        get { let v = d.double(forKey: "speed"); return v > 0 ? v : 24 }
        set { d.set(newValue, forKey: "speed") }
    }
    static var fps: Int {
        get { let v = d.integer(forKey: "fps"); return v > 0 ? v : 30 }
        set { d.set(newValue, forKey: "fps") }
    }
    static var aspect: String {
        get { d.string(forKey: "aspect") ?? "9:16" }
        set { d.set(newValue, forKey: "aspect") }
    }
    static var promptSize: Double {
        get { let v = d.double(forKey: "promptSize"); return v > 0 ? v : 22 }
        set { d.set(newValue, forKey: "promptSize") }
    }
    static var promptDelay: Double {
        get { d.object(forKey: "promptDelay") as? Double ?? 1.5 }
        set { d.set(newValue, forKey: "promptDelay") }
    }
    static var promptVisible: Bool {
        get { d.object(forKey: "promptVisible") as? Bool ?? true }
        set { d.set(newValue, forKey: "promptVisible") }
    }
    static var promptMode: String {
        get { d.string(forKey: "promptMode") ?? "voice" }
        set { d.set(newValue, forKey: "promptMode") }
    }
    static var keepEnd: Bool {
        get { d.bool(forKey: "keepEnd") }
        set { d.set(newValue, forKey: "keepEnd") }
    }
    static var voiceCommands: Bool {
        get { d.object(forKey: "voiceCommands") as? Bool ?? true }
        set { d.set(newValue, forKey: "voiceCommands") }
    }
    /// Off unless turned on in the sidebar: the only setting that lets take use the network.
    static var updateCheck: Bool {
        get { d.bool(forKey: "updateCheck") }
        set { d.set(newValue, forKey: "updateCheck") }
    }
    static var lastUpdateCheck: Double {
        get { d.double(forKey: "lastUpdateCheck") }
        set { d.set(newValue, forKey: "lastUpdateCheck") }
    }
    static var video: String? { get { d.string(forKey: "video") } set { d.set(newValue, forKey: "video") } }
    static var audio: String? { get { d.string(forKey: "audio") } set { d.set(newValue, forKey: "audio") } }
    static var folder: String? { get { d.string(forKey: "folder") } set { d.set(newValue, forKey: "folder") } }
}

// MARK: - Physics

struct Prompter {
    var offset: CGFloat = 0
    var v: CGFloat = 0
    var running = false
    var holdUntil: CFTimeInterval = 0
    var contentH: CGFloat = 0
    var last: CFTimeInterval = 0
    var manualUntil: CFTimeInterval = 0
    var needsReanchor = false

    var maxOffset: CGFloat { max(0, contentH - 60) }

    /// Voice mode: a critically damped spring towards the line being spoken.
    mutating func follow(_ target: CGFloat, _ now: CFTimeInterval) -> CGFloat {
        let dt = CGFloat(last == 0 ? 1.0 / 60 : min(0.05, now - last))
        last = now
        let k: CGFloat = 34
        v += (k * (target - offset) - 2 * sqrt(k) * v) * dt
        offset += v * dt
        if offset < 0 { offset = 0; v = max(v, 0) }
        return offset
    }

    mutating func step(_ now: CFTimeInterval, speed: CGFloat) -> CGFloat {
        let dt = last == 0 ? 1.0 / 60 : min(0.05, now - last)
        last = now
        let target = running && now >= holdUntil ? speed : 0
        v += (target - v) * (1 - exp(-4 * CGFloat(dt)))
        offset += v * CGFloat(dt)
        clamp()
        if offset >= maxOffset && running && contentH > 0 { running = false }
        return offset
    }

    mutating func nudge(_ d: CGFloat) { offset += d; clamp() }

    mutating func clamp() {
        if offset > maxOffset { offset = maxOffset; v = min(v, 0) }
        if offset < 0 { offset = 0; v = max(v, 0) }
    }

    mutating func reset() { offset = 0; v = 0 }
}

struct MeterState {
    var shown: Float = -60
    var peak: Float = -60
    var peakAt: CFTimeInterval = 0
    var last: CFTimeInterval = 0

    mutating func step(_ now: CFTimeInterval, level: Float, peakIn: Float) {
        let dt = Float(last == 0 ? 1.0 / 60 : min(0.05, now - last))
        last = now
        let t = max(level, -60)
        shown += (t - shown) * (1 - exp(-(t > shown ? 40 : 7) * dt))
        let p = max(peakIn, -60)
        if p >= peak { peak = p; peakAt = now }
        else if now - peakAt > 1.2 { peak += (shown - peak) * (1 - exp(-3 * dt)) }
    }
}

// MARK: - Model

struct Toast: Equatable {
    var id = UUID()
    var title: String
    var detail: String = ""
    var tone: Tone = .normal
    enum Tone { case normal, good, bad }
}

enum PromptMode: String { case voice, speed }

/// Plain text log of what the recogniser heard and what take decided. ~/Library/Logs/take-voice.log
/// Off unless enabled: defaults write design.ante.take voiceLog -bool true
final class VoiceLog {
    private let enabled = UserDefaults.standard.bool(forKey: "voiceLog")
    private let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/take-voice.log")
    private let q = DispatchQueue(label: "take.log")
    private let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    init() { if enabled { try? "".write(to: url, atomically: true, encoding: .utf8) } }
    func write(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let s = "\(f.string(from: Date()))  \(line())\n"
        q.async { [url] in
            // The throwing API: a full disk ends the line, not the app.
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(s.utf8))
            try? h.close()
        }
    }
}

struct SelectMenu {
    let id: String
    let options: [(id: String, label: String)]
    let selected: String?
    let onPick: (String) -> Void
}

@Observable
final class Model {
    let display = AVSampleBufferDisplayLayer()
    @ObservationIgnored lazy var engine = Engine(display: display)

    var videoDevices: [AVCaptureDevice] = []
    var audioDevices: [AVCaptureDevice] = []
    var videoDev: AVCaptureDevice?
    var audioDev: AVCaptureDevice?
    var turns = D.turns
    var fps = D.fps
    var aspect = Model.aspects.contains(D.aspect) ? D.aspect : "9:16"

    static let aspects = ["9:16", "4:5", "1:1", "16:9"]
    static func ratio(_ a: String) -> CGSize {
        let p = a.split(separator: ":").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : CGSize(width: 9, height: 16)
    }
    var ratio: CGSize { Model.ratio(aspect) }
    var recording = false
    /// A stopped take is still being finished on disk. Quitting or starting now would lose or skip it.
    var saving = false
    var recStart: Date?
    /// What the camera really delivers, which can be less than the chosen rate.
    var liveFps: Int?
    var hasSignal = false
    var frameSize = CGSize.zero
    var script = D.script
    var speed = D.speed
    var promptVisible = D.promptVisible
    var promptSize = D.promptSize
    var promptDelay = D.promptDelay
    var promptRunning = false
    var promptMode: PromptMode = PromptMode(rawValue: D.promptMode) ?? .voice
    var voiceCommands = D.voiceCommands
    var keepEnd = D.keepEnd
    var updateCheck = D.updateCheck
    /// A newer version seen on take.ante.design, shown in the sidebar until this app is updated.
    var updateAvailable: String?
    var listening = false
    var countdown: Int?
    var scriptVersion = 0
    var heardTail = ""
    var folder: URL
    var take = 1
    var toast: Toast?
    var editing = false
    var openSelect: String?
    var cameraDenied = false
    var micDenied = false

    @ObservationIgnored var level: Float = -160
    @ObservationIgnored var peak: Float = -160
    @ObservationIgnored var lastFrame: CFTimeInterval = 0
    @ObservationIgnored private var frameCount = 0
    /// Starts at launch, so the first "frames in 5 s" line counts 5 s, not the first tenth of a second.
    @ObservationIgnored private var frameLogAt = CACurrentMediaTime()
    @ObservationIgnored var prompt = Prompter()
    @ObservationIgnored var meter = MeterState()
    @ObservationIgnored var onSavedAll: (() -> Void)?
    @ObservationIgnored private var signalTimer: Timer?
    @ObservationIgnored let listener = Listener()
    @ObservationIgnored let tracker = Tracker()
    @ObservationIgnored var selectMenu: SelectMenu?
    @ObservationIgnored private var speechOK = false
    @ObservationIgnored private var heardGen = -1
    @ObservationIgnored private var arrivals: [CFTimeInterval] = []
    @ObservationIgnored private var lastHeardAt: CFTimeInterval = 0
    @ObservationIgnored private var pending: (cmd: Command, key: String, media: Double?, arrival: CFTimeInterval, gen: Int, end: Int,
                                               endMedia: Double?)?
    @ObservationIgnored private var lastTailUpdate: CFTimeInterval = 0
    @ObservationIgnored private let log = VoiceLog()
    @ObservationIgnored private let chime = Chime()
    @ObservationIgnored private var countdownSounds = false
    @ObservationIgnored private var lastFiredIdent: Double = -1
    @ObservationIgnored private var lastFiredTimed = false
    @ObservationIgnored private var prevTexts: [String] = []
    @ObservationIgnored private var cooldownUntil: CFTimeInterval = 0
    @ObservationIgnored private var pendingIdent: (Double, Bool) = (-1, false)
    @ObservationIgnored private var againAfterSave = false
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var takeStartCursor = 0
    @ObservationIgnored private var takeStartOffset: CGFloat = 0
    @ObservationIgnored private var badQueue: [Toast] = []
    @ObservationIgnored private var fpsWarned = ""
    @ObservationIgnored private let updater = Updater()
    @ObservationIgnored private var updateTimer: Timer?

    init() {
        folder = Model.defaultFolder()
        engine.setTurns(turns)
        engine.setAspect(Model.ratio(aspect))
        engine.onFrame = { [weak self] size in
            guard let self else { return }
            lastFrame = CACurrentMediaTime()
            frameCount += 1
            if frameSize != size { frameSize = size }
        }
        engine.onLevel = { [weak self] avg, peak in self?.level = avg; self?.peak = peak }
        engine.onLive = { [weak self] in self?.recStart = Date() }
        engine.onSaved = { [weak self] url, err, discarded in self?.saved(url, err, discarded) }
        engine.onFps = { [weak self] real in self?.deliveredFps(real) }
        let l = listener
        engine.onAudio = { sb in l.append(sb) }
        listener.onResult = { [weak self] segs, gen in self?.heard(segs, gen) }
        listener.onFail = { [weak self] why in
            self?.listening = false
            self?.say("Voice is off", why, .bad)
        }
        let lg = log
        listener.onLog = { lg.write($0) }
        engine.onLog = { lg.write($0) }
        tracker.load(script)
        startUpdateChecks()
        // First launch: the onboarding script says "read this out loud and watch it keep up", so it has to be following already.
        if D.d.object(forKey: "script") == nil && promptMode == .voice {
            prompt.running = true
            promptRunning = true
        }
        take = nextTake()

        signalTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            let s = now - lastFrame < 1
            if s != hasSignal { hasSignal = s; log.write("signal \(s ? "on" : "off")") }
            if now - frameLogAt >= 5 {
                log.write("frames \(frameCount) in 5 s, camera \(videoDev?.localizedName ?? "none")")
                frameCount = 0
                frameLogAt = now
            }
            if prompt.running != promptRunning { promptRunning = prompt.running }
            confirmPending(now)
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        nc.addObserver(self, selector: #selector(devicesChanged), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        ws.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    // MARK: Start

    func start(camera: Bool, mic: Bool) {
        log.write("start camera=\(camera) mic=\(mic) status=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        micDenied = !mic
        guard camera else {
            cameraDenied = true
            say("Camera access is off", "System Settings, Privacy & Security, Camera.", .bad)
            return
        }
        refreshLists()
        videoDev = pickVideo()
        audioDev = pickAudio()
        apply()
        if videoDev == nil { say("No camera found", "Connect the capture card.", .bad) }
        else if !mic { say("Microphone access is off", "System Settings, Privacy & Security, Microphone.", .bad) }
        Listener.authorize { [weak self] ok in
            guard let self else { return }
            speechOK = ok
            if !ok && (voiceCommands || promptMode == .voice) {
                say("Speech recognition is off", "System Settings, Privacy & Security, Speech Recognition.", .bad)
            }
            updateListening()
        }
    }

    private func apply() { engine.use(video: videoDev, audio: audioDev, fps: fps) }

    private func refreshLists() {
        videoDevices = Engine.videoDevices
        audioDevices = Engine.audioDevices
    }

    // MARK: Devices

    private func pickVideo() -> AVCaptureDevice? {
        let list = videoDevices
        if let id = D.video, let d = list.first(where: { $0.uniqueID == id }) { return d }
        return list.first { n in ["usb3", "cam link", "capture", "hdmi"].contains { n.localizedName.lowercased().contains($0) } }
            ?? list.first { $0.deviceType == .external }
            ?? list.first
    }

    private func pickAudio() -> AVCaptureDevice? {
        let list = audioDevices
        if let id = D.audio, let d = list.first(where: { $0.uniqueID == id }) { return d }
        if let d = list.first(where: { $0.localizedName.lowercased().contains("dji") }) { return d }
        if let v = videoDev?.localizedName.lowercased(), let first = v.split(separator: " ").first,
           let d = list.first(where: { $0.localizedName.lowercased().hasPrefix(first) }) { return d }
        if let d = list.first(where: { n in ["usb3", "hdmi", "capture", "cam link"].contains { n.localizedName.lowercased().contains($0) } }) { return d }
        return AVCaptureDevice.default(for: .audio) ?? list.first
    }

    func selectVideo(_ id: String) {
        guard !recording, let d = videoDevices.first(where: { $0.uniqueID == id }) else { return }
        videoDev = d
        D.video = id
        apply()
    }

    func selectAudio(_ id: String) {
        guard !recording, let d = audioDevices.first(where: { $0.uniqueID == id }) else { return }
        audioDev = d
        D.audio = id
        apply()
    }

    func cycleVideo() {
        guard !recording else { return }
        refreshLists()
        guard !videoDevices.isEmpty else { return }
        let i = ((videoDevices.firstIndex { $0.uniqueID == videoDev?.uniqueID } ?? -1) + 1) % videoDevices.count
        selectVideo(videoDevices[i].uniqueID)
        say("Camera", videoDevices[i].localizedName)
    }

    func cycleAudio() {
        guard !recording else { return }
        refreshLists()
        guard !audioDevices.isEmpty else { return }
        let i = ((audioDevices.firstIndex { $0.uniqueID == audioDev?.uniqueID } ?? -1) + 1) % audioDevices.count
        selectAudio(audioDevices[i].uniqueID)
        say("Microphone", audioDevices[i].localizedName)
    }

    @objc private func devicesChanged(_ n: Notification) {
        if let d = n.object as? AVCaptureDevice { log.write("\(n.name == AVCaptureDevice.wasConnectedNotification ? "connected" : "disconnected") \(d.localizedName)") }
        DispatchQueue.main.async { [self] in
            refreshLists()
            guard !recording else { return }
            let v = pickVideo(), a = pickAudio()
            guard v?.uniqueID != videoDev?.uniqueID || a?.uniqueID != audioDev?.uniqueID else { return }
            videoDev = v
            audioDev = a
            apply()
        }
    }

    // MARK: Settings

    func setTurns(_ n: Int) {
        guard !recording else { say("Rotation is locked", "Stop the recording first."); return }
        turns = ((n % 4) + 4) % 4
        D.turns = turns
        engine.setTurns(turns)
    }

    func setAspect(_ a: String) {
        guard !recording else { say("Format is locked", "Stop the recording first."); return }
        aspect = a
        D.aspect = a
        engine.setAspect(Model.ratio(a))
    }

    func setFps(_ f: Int) {
        guard !recording else { return }
        fps = f
        D.fps = f
        apply()
    }

    /// The camera settled on a rate. The header shows that one, and says so once when it is not the chosen one.
    private func deliveredFps(_ real: Int) {
        liveFps = real
        let key = "\(videoDev?.uniqueID ?? "")-\(fps)"
        guard abs(real - fps) > 1, fpsWarned != key else { return }
        fpsWarned = key
        say("\(videoDev?.localizedName ?? "This camera") delivers \(real) fps", "Takes record at \(real), not \(fps).")
    }

    func setSpeed(_ s: Double) {
        speed = min(200, max(4, s))
        D.speed = speed
    }

    func setScript(_ s: String) {
        script = s
        D.script = s
        prompt.reset()
        tracker.load(s)
        tracker.cursor = 0
        scriptVersion += 1
        updateListening()
    }

    func setPromptMode(_ m: PromptMode) {
        promptMode = m
        D.promptMode = m.rawValue
        prompt.v = 0
        updateListening()
    }

    func toggleKeepEnd() {
        keepEnd.toggle()
        D.keepEnd = keepEnd
    }

    func toggleUpdateCheck() {
        updateCheck.toggle()
        D.updateCheck = updateCheck
        if updateCheck { checkForUpdate(force: true) } else { updateAvailable = nil }
        startUpdateChecks()
    }

    /// While the switch is on: a check at launch, then the timer looks every hour whether a day has passed.
    private func startUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = nil
        guard updateCheck else { return }
        checkForUpdate(force: false)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkForUpdate(force: false) }
    }

    private func checkForUpdate(force: Bool) {
        let now = Date().timeIntervalSince1970
        guard updateCheck, force || now - D.lastUpdateCheck >= Updater.interval else { return }
        D.lastUpdateCheck = now
        updater.check { [weak self] newer in
            guard let self, updateCheck else { return }
            let wasKnown = updateAvailable == newer
            updateAvailable = newer
            if let v = newer, !wasKnown { say("take \(v) is out", "Download it from take.ante.design.") }
            else if newer == nil && force { say("take is up to date", "Version \(Updater.currentVersion).") }
        }
    }

    func openUpdatePage() { NSWorkspace.shared.open(Updater.site) }

    func toggleVoiceCommands() {
        voiceCommands.toggle()
        D.voiceCommands = voiceCommands
        updateListening()
    }

    func rewindTop() {
        prompt.reset()
        prompt.running = false
        promptRunning = false
        tracker.cursor = 0
    }

    func scroll(_ d: CGFloat) {
        prompt.nudge(d)
        if promptMode == .voice {
            prompt.manualUntil = CACurrentMediaTime() + 1.2
            prompt.needsReanchor = true
        }
    }

    func setPromptSize(_ v: Double) {
        promptSize = min(64, max(14, v))
        D.promptSize = promptSize
    }

    func togglePromptVisible() {
        promptVisible.toggle()
        D.promptVisible = promptVisible
        updateListening()
    }

    func togglePrompter() {
        if !prompt.running && prompt.offset >= prompt.maxOffset && prompt.contentH > 0 { prompt.reset() }
        prompt.running.toggle()
        prompt.holdUntil = 0
        promptRunning = prompt.running
    }

    func setPromptDelay(_ v: Double) {
        promptDelay = min(10, max(0, (v * 2).rounded() / 2))
        D.promptDelay = promptDelay
    }

    // MARK: Folder

    static func externalVolume() -> URL? {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return vols.first { v in
            guard let r = try? v.resourceValues(forKeys: keys) else { return false }
            return r.volumeIsInternal == false && r.volumeIsReadOnly == false && r.volumeIsBrowsable == true && r.volumeIsRootFileSystem != true
        }
    }

    static func defaultFolder() -> URL {
        if let saved = D.folder { return URL(fileURLWithPath: saved) }
        if let v = externalVolume() { return v.appendingPathComponent("take") }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("take")
    }

    @objc private func volumesChanged() {
        DispatchQueue.main.async { [self] in
            guard !recording, D.folder == nil else { return }
            let f = Model.defaultFolder()
            if f != folder { folder = f; take = nextTake() }
        }
    }

    var onExternal: Bool { folder.pathComponents.count > 2 && folder.pathComponents[1] == "Volumes" }

    var folderName: String {
        let c = folder.pathComponents
        if onExternal { return c[2] }
        return folder.deletingLastPathComponent().lastPathComponent
    }

    var folderPath: String {
        let c = folder.pathComponents
        if onExternal { return "/" + c.dropFirst(3).joined(separator: "/") }
        return folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func chooseFolder() {
        guard !recording else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Record here"
        p.directoryURL = folder
        if p.runModal() == .OK, let url = p.url {
            folder = url
            D.folder = url.path
            take = nextTake()
        }
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: Recording

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func fileName(_ n: Int) -> String {
        "\(Model.day.string(from: Date()))_take-\(String(format: "%02d", n)).mov"
    }

    func nextTake() -> Int {
        let prefix = "\(Model.day.string(from: Date()))_take-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let used = names.compactMap { n -> Int? in
            guard n.hasPrefix(prefix), n.hasSuffix(".mov") else { return nil }
            return Int(n.dropFirst(prefix.count).dropLast(4))
        }
        return (used.max() ?? 0) + 1
    }

    func toggleRecord() {
        if countdown != nil { cancelCountdown(); return }
        if recording {
            engine.stop()
            recording = false
            saving = true
            recStart = nil
            rewindTop()
            return
        }
        startRecording()
    }

    private func startRecording() {
        guard hasSignal else { say("No signal", "Nothing to record yet.", .bad); return }
        guard !saving else { say("Saving the last take", "Start again in a moment."); return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            say("Cannot write here", folderPath, .bad)
            return
        }
        openSelect = nil
        take = nextTake()
        engine.record(to: folder.appendingPathComponent(fileName(take)))
        recording = true
        recStart = nil
        if promptMode == .speed {
            prompt.reset()
            prompt.holdUntil = CACurrentMediaTime() + promptDelay
        } else {
            prompt.holdUntil = 0
        }
        takeStartCursor = tracker.cursor
        takeStartOffset = prompt.offset
        prompt.running = !script.isEmpty
        promptRunning = prompt.running
    }

    // MARK: Countdown

    func beginCountdown(sounds: Bool = true) {
        guard hasSignal else { say("No signal", "Nothing to record yet.", .bad); return }
        countdownTimer?.invalidate()
        countdownSounds = sounds
        countdown = 3
        if sounds { chime.tick() }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self, let c = countdown else { t.invalidate(); return }
            if c <= 1 {
                t.invalidate()
                countdown = nil
                if countdownSounds {
                    chime.go()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.startRecording() }
                } else {
                    startRecording()
                }
            } else {
                countdown = c - 1
                if countdownSounds { chime.tick() }
            }
        }
    }

    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
    }

    // MARK: Voice

    func updateListening() {
        // Without the microphone nothing reaches the recogniser, so "Listening" would be a lie.
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let need = speechOK && micOK && (voiceCommands || (promptMode == .voice && promptVisible && !script.isEmpty))
        guard need else {
            if listener.running { listener.stop() }
            listening = false
            return
        }
        let loc = Listener.locale(for: script)
        if listener.running && listener.locale?.identifier == loc.identifier { listening = true; return }
        let hints = Array(Set(script.split { $0.isWhitespace }.map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 4 && $0.first?.isUppercase == true }))
        if let why = listener.start(locale: loc, hints: hints) {
            listening = false
            say("Voice is off", why, .bad)
        } else {
            listening = true
        }
    }

    private func heard(_ segs: [Listener.Seg], _ gen: Int) {
        let now = CACurrentMediaTime()
        let texts = segs.map(\.text)
        var common = 0
        // A shrinking transcript means the recogniser started a new utterance: nothing carries over.
        if gen == heardGen && texts.count >= prevTexts.count {
            while common < min(texts.count, prevTexts.count, arrivals.count), texts[common] == prevTexts[common] { common += 1 }
        }
        heardGen = gen
        // A word keeps its arrival time only while the recogniser leaves it unchanged.
        arrivals = Array(arrivals.prefix(common)) + Array(repeating: now, count: texts.count - common)
        if texts.count > common || texts.count != prevTexts.count {
            lastHeardAt = now
            log.write("heard [\(gen)] " + texts.suffix(8).joined(separator: " "))
        }
        prevTexts = texts
        // Words that normalise to nothing (dashes, stray punctuation) are dropped, keeping a map back to the segments.
        let pairs = segs.enumerated().compactMap { i, sg -> (Int, String)? in
            let n = Tracker.norm(sg.text)
            return n.isEmpty ? nil : (i, n)
        }
        let toks = pairs.map(\.1)
        guard !toks.isEmpty else { return }

        if now - lastTailUpdate > 0.1 {
            lastTailUpdate = now
            let tail = segs.suffix(8).map(\.text).joined(separator: " ")
            if tail != heardTail { heardTail = tail }
        }

        var commandAt: Int?
        var found = voiceCommands && !editing ? CommandWords.find(toks) : nil
        if let (cmd, tj, len) = found {
            // A misheard form that is really words of the script ("give and take and") is reading, not a command.
            let spoken = toks[tj..<(tj + len)].joined()
            if !CommandWords.exact.contains(spoken) && tracker.contains(joined: spoken, maxWords: len + 1) {
                log.write("script words, not \(cmd.rawValue): \"\(spoken)\"")
                found = nil
            }
        }
        // A command the script itself says, right where the reading is, is a line being read, not an order.
        // The exception is the script's final words, like the "take end." that closes a reel.
        if let (cmd, tj, _) = found, prompt.running, promptVisible {
            let near = promptMode == .voice ? tracker.cursor : nil
            let (inScript, last) = tracker.scriptSays(cmd, before: Array(toks[..<tj]), around: near)
            if inScript && !last {
                log.write("script line, not \(cmd.rawValue)")
                found = nil
            }
        }
        if let (cmd, tj, len) = found {
            commandAt = tj
            let ti = pairs[tj].0
            let lastI = pairs[tj + len - 1].0
            let isolated: Bool
            if ti == 0 { isolated = true }
            else if segs[ti].timed && segs[ti - 1].timed { isolated = segs[ti].start - segs[ti - 1].end >= 0.2 }
            else { isolated = arrivals[ti] - arrivals[ti - 1] >= 0.3 }
            let key = "\(gen)-\(ti)-\(cmd.rawValue)"
            // Same spoken instance as the last fired one (the recogniser revising earlier words shifts indices,
            // so identity is the arrival time, not the position), or still inside the cooldown.
            let timed = segs[ti].timed
            let ident = timed ? segs[ti].start : arrivals[ti]
            let same = timed == lastFiredTimed && (timed ? abs(ident - lastFiredIdent) < 0.3 : ident <= lastFiredIdent + 0.05)
            let already = same || now < cooldownUntil
            if isolated && !already {
                if pending?.key != key {
                    pending = (cmd, key, timed ? segs[ti].start : nil, arrivals[ti], gen, tj + len,
                               segs[lastI].timed ? segs[lastI].end : nil)
                    pendingIdent = (ident, timed)
                    log.write("candidate \(cmd.rawValue) in \"\(toks.suffix(6).joined(separator: " "))\"")
                } else if segs[lastI].timed, let p = pending {
                    // Same command, a later result: its last word may have grown since. Keep take end cuts after the latest end.
                    pending?.endMedia = max(p.endMedia ?? segs[lastI].end, segs[lastI].end)
                }
            } else if !isolated {
                log.write("ignored \(cmd.rawValue), no pause before it, in \"\(toks.suffix(6).joined(separator: " "))\"")
            }
        } else if let p = pending, p.gen == gen, toks.count > p.end {
            log.write("dropped \(p.cmd.rawValue), speech continued")
            pending = nil
        }

        if promptMode == .voice && prompt.running && now >= prompt.manualUntil {
            let before = tracker.cursor
            tracker.feed(commandAt.map { Array(toks[..<$0]) } ?? toks)
            if tracker.cursor != before { log.write("follow \(before) -> \(tracker.cursor)") }
        }
    }

    private func confirmPending(_ now: CFTimeInterval) {
        guard let p = pending, now - p.arrival >= 0.45, now - lastHeardAt >= 0.35 else { return }
        pending = nil
        lastFiredIdent = pendingIdent.0
        lastFiredTimed = pendingIdent.1
        cooldownUntil = now + 1.5
        run(p.cmd, media: p.media, arrival: p.arrival, endMedia: p.endMedia)
    }

    /// Same as speaking the command, from a click. Nothing to trim, so the take ends where it is.
    func trigger(_ c: Command) {
        openSelect = nil
        cooldownUntil = CACurrentMediaTime() + 1.0
        run(c, media: nil, arrival: CACurrentMediaTime(), spoken: false)
    }

    func applies(_ c: Command) -> Bool {
        switch c {
        case .start: return !recording && countdown == nil
        case .again: return recording || countdown != nil || hasSignal
        case .end: return recording || countdown != nil
        case .reset: return !script.isEmpty
        }
    }

    private func run(_ c: Command, media: Double?, arrival: CFTimeInterval, spoken: Bool = true,
                     endMedia: Double? = nil) {
        var cutAt: CMTime? = spoken ? CMTime(seconds: (media ?? (arrival - 0.7)) - 0.15, preferredTimescale: 600) : nil
        if c == .end && spoken && keepEnd {
            // Keep the spoken "take end" in the take: cut just after it instead of just before it,
            // and never later than now, so the end tone that follows stays out of the file.
            // Without timestamps the word's end is unknown (a partial result can show it before it is fully said),
            // so the cut is now: by then the recogniser has heard nothing new for 0.35 s.
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds - 0.05
            cutAt = CMTime(seconds: min(endMedia.map { $0 + 0.35 } ?? now, now), preferredTimescale: 600)
        }
        log.write("fired \(c.rawValue) recording=\(recording) countdown=\(countdown ?? 0)")
        say("take " + c.rawValue, commandEffect(c))
        switch c {
        case .reset:
            // The tone would land in the take. The toast confirms it.
            if !recording { chime.ack() }
            rewindTop()
            if !script.isEmpty {
                prompt.holdUntil = 0
                prompt.running = true
                promptRunning = true
            }
        case .start:
            guard !recording, countdown == nil else { return }
            beginCountdown()
        case .again:
            if countdown != nil { beginCountdown(); return }
            rewindTake()
            if recording {
                chime.discard()
                againAfterSave = true
                engine.stop(discard: true)
                recording = false
                saving = true
                recStart = nil
            } else {
                beginCountdown()
            }
        case .end:
            if countdown != nil { cancelCountdown(); chime.end(); return }
            guard recording else { chime.ack(); return }
            engine.stop(endAt: cutAt, discard: false)
            chime.end()
            recording = false
            saving = true
            recStart = nil
            rewindTop()
        }
    }

    private func commandEffect(_ c: Command) -> String {
        switch c {
        case .start: return recording ? "Already recording" : "Counting in"
        case .again: return recording ? "Discarded, counting in" : "Counting in"
        case .end: return recording ? "Stopped and kept" : "Not recording"
        case .reset: return "Teleprompter from the top"
        }
    }

    private func rewindTake() {
        prompt.running = false
        if promptMode == .voice {
            tracker.cursor = takeStartCursor
        } else {
            prompt.offset = takeStartOffset
            prompt.v = 0
        }
    }

    /// Quit waits for the take on disk, whether it is still recording or already finishing.
    func stopForQuit(_ done: @escaping () -> Void) {
        if recording {
            onSavedAll = done
            toggleRecord()
        } else if saving {
            onSavedAll = done
        } else {
            done()
        }
    }

    private func saved(_ url: URL?, _ err: Error?, _ discarded: Bool) {
        if let err { say("Not saved", err.localizedDescription, .bad) }
        else if discarded, let url { say("Discarded", "Moved to discarded/" + url.lastPathComponent) }
        else if let url { say("Saved", url.lastPathComponent, .good) }
        recording = false
        saving = false
        recStart = nil
        take = nextTake()
        if let done = onSavedAll { onSavedAll = nil; done() }
        if againAfterSave {
            againAfterSave = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.beginCountdown() }
        }
    }

    // MARK: Toast

    /// A problem is never replaced unseen: a second problem waits its turn, other news shows first and the problem comes back after it.
    func say(_ title: String, _ detail: String = "", _ tone: Toast.Tone = .normal) {
        log.write("toast \(title): \(detail)")
        let t = Toast(title: title, detail: detail, tone: tone)
        if let cur = toast, cur.tone == .bad {
            if tone == .bad { badQueue.append(t); return }
            var again = cur
            again.id = UUID()
            badQueue.insert(again, at: 0)
        }
        show(t)
    }

    private func show(_ t: Toast) {
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + (t.tone == .bad ? 7 : 3.5)) { [weak self] in
            guard let self, toast?.id == t.id else { return }
            if badQueue.isEmpty { toast = nil } else { show(badQueue.removeFirst()) }
        }
    }
}

// MARK: - Components

struct Kbd: View {
    let key: String
    var dark = false
    var body: some View {
        Text(key)
            .font(.mono(11, .medium))
            .foregroundStyle(dark ? Color.subtle : Color.mutedFg)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(dark ? Color(hex: 0xE4E4E7) : Color.muted)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(dark ? Color(hex: 0xD4D4D8) : Color.line))
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.mono(12))
            .foregroundStyle(Color.mutedFg)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .overlay(Capsule().strokeBorder(Color.line))
    }
}

struct FieldLabel: View {
    let title: String
    var key: String?
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.geist(13, .medium)).foregroundStyle(Color.fg)
            Spacer(minLength: 0)
            if let key { Kbd(key: key) }
        }
        .frame(height: 20)
    }
}

struct SelectAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct Select: View {
    let id: String
    let icon: String
    let value: String
    let options: [(id: String, label: String)]
    let selected: String?
    let onPick: (String) -> Void
    @Bindable var model: Model

    private var open: Bool { model.openSelect == id }

    var body: some View {
        Button {
            if open { model.openSelect = nil } else {
                model.selectMenu = SelectMenu(id: id, options: options, selected: selected, onPick: onPick)
                model.openSelect = id
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mutedFg).frame(width: 16)
                Text(value).font(.geist(13)).foregroundStyle(Color.fg).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.subtle)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color.bg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(open ? Color.mutedFg.opacity(0.6) : Color.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: SelectAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

struct DropdownList: View {
    let menu: SelectMenu
    @Bindable var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(menu.options, id: \.id) { o in
                OptionRow(label: o.label, checked: o.id == menu.selected) {
                    menu.onPick(o.id)
                    model.openSelect = nil
                }
            }
        }
        .padding(4)
        .background(Color.bg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
    }
}

struct OptionRow: View {
    let label: String
    let checked: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label).font(.geist(13)).foregroundStyle(Color.fg).lineLimit(1)
                Spacer(minLength: 8)
                if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.fg) }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(hover ? Color.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct StepperRow: View {
    let title: String
    let value: String
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.geist(13)).foregroundStyle(Color.mutedFg)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                StepButton(icon: "minus", action: minus)
                Rectangle().fill(Color.line).frame(width: 1, height: 32)
                Text(value).font(.mono(13, .medium)).foregroundStyle(Color.fg).frame(width: 56)
                Rectangle().fill(Color.line).frame(width: 1, height: 32)
                StepButton(icon: "plus", action: plus)
            }
            .frame(height: 32)
            .background(Color.bg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.line))
        }
    }
}

struct StepButton: View {
    let icon: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.fg)
                .frame(width: 32, height: 32)
                .background(hover ? Color.accent : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct Switch: View {
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Color.fg : Color.accent)
                Circle().fill(on ? Color.bg : Color.fg).frame(width: 16, height: 16).padding(2)
            }
            .frame(width: 36, height: 20)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: on)
        }
        .buttonStyle(.plain)
    }
}

struct Segmented: View {
    let items: [String]
    let index: Int
    let onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                Button { onPick(i) } label: {
                    Text(items[i])
                        .font(.geist(13, .medium))
                        .foregroundStyle(i == index ? Color.fg : Color.mutedFg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(i == index ? Color.bg : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(i == index ? Color.line : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.muted)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct OutlineButton: View {
    let icon: String
    let title: String
    var key: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.geist(13, .medium))
                if let key { Spacer(minLength: 4); Kbd(key: key) }
            }
            .foregroundStyle(Color.fg)
            .padding(.leading, 12)
            .padding(.trailing, key == nil ? 12 : 8)
            .frame(maxWidth: .infinity, alignment: key == nil ? .center : .leading)
            .frame(height: 36)
            .background(hover ? Color.accent : Color.bg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct IconButton: View {
    let icon: String
    var help = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.fg)
                .frame(width: 36, height: 36)
                .background(hover ? Color.accent : Color.bg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Video

final class VideoHost: NSView {
    private let video: AVSampleBufferDisplayLayer
    init(_ layer: AVSampleBufferDisplayLayer) {
        video = layer
        super.init(frame: .zero)
        wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        layer.videoGravity = .resizeAspect
        self.layer?.addSublayer(layer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
    }
}

struct VideoView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeNSView(context: Context) -> VideoHost { VideoHost(layer) }
    func updateNSView(_ v: VideoHost, context: Context) {}
}

// MARK: - Preview

/// The script, laid out with TextKit so every word has a known position.
final class PromptNSView: NSView {
    private weak var model: Model?
    private let tv = NSTextView(frame: .zero)
    private var link: CADisplayLink?
    private var builtVersion = -1
    private var builtWidth: CGFloat = -1
    private var builtSize: Double = -1
    private var shownCursor = -1
    private var lineH: CGFloat = 30

    override var isFlipped: Bool { true }

    init(model: Model) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        addSubview(tv)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, link == nil {
            let l = displayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        } else if window == nil {
            link?.invalidate()
            link = nil
        }
    }

    private func rebuild() {
        guard let m = model, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let w = max(10, bounds.width - 48)
        let size = CGFloat(m.promptSize)
        let font = NSFont(name: "Geist-Medium", size: size) ?? .systemFont(ofSize: size, weight: .medium)
        let p = NSMutableParagraphStyle()
        p.lineSpacing = floor(size * 0.32)
        tv.textStorage?.setAttributedString(NSAttributedString(string: m.script, attributes: [
            .font: font, .foregroundColor: NSColor.white, .paragraphStyle: p,
        ]))
        tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        tv.frame = NSRect(x: 24, y: 24, width: w, height: ceil(used.height) + size * 2)
        m.prompt.contentH = ceil(used.height)
        lineH = ceil(lm.defaultLineHeight(for: font) + p.lineSpacing)
        builtVersion = m.scriptVersion
        builtWidth = bounds.width
        builtSize = m.promptSize
        shownCursor = -1
    }

    private func lineTop(_ char: Int) -> CGFloat {
        guard let lm = tv.layoutManager, let len = tv.textStorage?.length, len > 0 else { return 0 }
        let g = lm.glyphIndexForCharacter(at: min(max(0, char), len - 1))
        return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY
    }

    private func dim(upTo char: Int) {
        guard let ts = tv.textStorage, ts.length > 0 else { return }
        ts.beginEditing()
        ts.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: ts.length))
        let end = min(char, ts.length)
        if end > 0 { ts.addAttribute(.foregroundColor, value: NSColor(white: 1, alpha: 0.36), range: NSRange(location: 0, length: end)) }
        ts.endEditing()
    }

    @objc private func tick() {
        guard let m = model else { return }
        if m.scriptVersion != builtVersion || abs(bounds.width - builtWidth) > 0.5 || m.promptSize != builtSize { rebuild() }
        let now = CACurrentMediaTime()
        let offset: CGFloat
        if m.promptMode == .voice {
            if now < m.prompt.manualUntil {
                m.prompt.last = now
                offset = m.prompt.offset
            } else {
                if m.prompt.needsReanchor, let lm = tv.layoutManager, let tc = tv.textContainer {
                    m.prompt.needsReanchor = false
                    let c = lm.characterIndex(for: NSPoint(x: 1, y: m.prompt.offset + lineH), in: tc,
                                              fractionOfDistanceBetweenInsertionPoints: nil)
                    m.tracker.cursor = m.tracker.word(atChar: c)
                }
                let c = m.tracker.cursor
                offset = m.prompt.follow(max(0, lineTop(m.tracker.charIndex(c)) - lineH), now)
            }
            if m.tracker.cursor != shownCursor {
                shownCursor = m.tracker.cursor
                dim(upTo: m.tracker.charIndex(shownCursor))
            }
        } else {
            if shownCursor != -2 { shownCursor = -2; dim(upTo: 0) }
            offset = m.prompt.step(now, speed: CGFloat(m.speed))
        }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tv.frame.origin.y = ((24 - offset) * scale).rounded() / scale
        CATransaction.commit()
    }
}

struct PromptText: NSViewRepresentable {
    let model: Model
    func makeNSView(context: Context) -> PromptNSView { PromptNSView(model: model) }
    func updateNSView(_ v: PromptNSView, context: Context) {}
}

struct PromptOverlay: View {
    let model: Model
    let width: CGFloat
    let height: CGFloat

    /// The band the script lives in: a bigger share of a wide frame, where there is less height to read from.
    private var band: CGFloat { floor(height * (width > height ? 0.5 : 0.42)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.72), location: 0),
                .init(color: .black.opacity(0.72), location: 0.78),
                .init(color: .black.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            PromptText(model: model)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 20)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: floor(band * 0.32))
                    }
                }
        }
        .frame(width: width, height: band)
        .clipped()
        .allowsHitTesting(false)
    }
}

struct Preview: View {
    let model: Model
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoView(layer: model.display)
            if !model.script.isEmpty && model.promptVisible { PromptOverlay(model: model, width: size.width, height: size.height) }
            if !model.hasSignal {
                VStack(spacing: 10) {
                    Image(systemName: model.cameraDenied ? "video.slash" : "cable.connector")
                        .font(.system(size: 20)).foregroundStyle(Color.mutedFg)
                    Text(model.cameraDenied ? "Camera access is off" : "No signal").font(.geist(14, .medium)).foregroundStyle(Color.fg)
                    Text(model.cameraDenied ? "Allow it in System Settings" : "Check the HDMI cable and the camera")
                        .font(.geist(12)).foregroundStyle(Color.mutedFg)
                }
                .frame(width: size.width, height: size.height)
            }
            if model.script.isEmpty && model.hasSignal {
                HStack(spacing: 6) {
                    Text("Press").font(.geist(12)).foregroundStyle(Color.mutedFg)
                    Kbd(key: "E")
                    Text("to add a script").font(.geist(12)).foregroundStyle(Color.mutedFg)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(16)
            }
            if let c = model.countdown {
                ZStack {
                    Color.black.opacity(0.45)
                    Text("\(c)")
                        .font(.geist(128, .semibold))
                        .foregroundStyle(Color.fg)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: c)
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.recording ? Color.dangerStrong : Color.line, lineWidth: model.recording ? 2 : 1))
    }
}

struct RecordButton: View {
    @Bindable var model: Model
    @State private var hover = false

    var body: some View {
        Button { model.toggleRecord() } label: {
            HStack(spacing: 10) {
                if model.recording {
                    RoundedRectangle(cornerRadius: 2).fill(Color.fg).frame(width: 10, height: 10)
                    Text("Stop").font(.geist(14, .semibold))
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Text(Timecode.string(model.recStart)).font(.mono(13, .medium)).foregroundStyle(Color.fg.opacity(0.85))
                    }
                } else {
                    Circle().fill(Color.danger).frame(width: 10, height: 10)
                    Text("Record").font(.geist(14, .semibold))
                }
                Kbd(key: "Space", dark: !model.recording)
            }
            .foregroundStyle(model.recording ? Color.fg : Color.bg)
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(height: 40)
            .background(model.recording ? (hover ? Color(hex: 0xB91C1C) : Color.dangerStrong) : (hover ? Color(hex: 0xE4E4E7) : Color.fg))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

enum Timecode {
    static func string(_ start: Date?) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start ?? Date())))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Meter

struct MeterView: View {
    let model: Model
    static let n = 24
    static let bw: CGFloat = 6
    static let gap: CGFloat = 3

    var body: some View {
        TimelineView(.animation) { _ in
            let _ = model.meter.step(CACurrentMediaTime(), level: model.level, peakIn: model.peak)
            let shown = model.meter.shown
            let peak = model.meter.peak
            HStack(spacing: 0) {
                Canvas { ctx, _ in
                    for i in 0..<MeterView.n {
                        let lo = -48 + Float(i) * 2
                        let hot = lo >= -4
                        let lit = shown > lo
                        let isPeak = !lit && peak > lo && peak <= lo + 2
                        let inZone = lo >= -18 && lo < -6
                        let c: Color = lit || isPeak ? (hot ? .danger : .fg) : (inZone ? .zone : .accent)
                        let r = CGRect(x: CGFloat(i) * (MeterView.bw + MeterView.gap), y: 0, width: MeterView.bw, height: 12)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(c))
                    }
                }
                .frame(width: CGFloat(MeterView.n) * (MeterView.bw + MeterView.gap) - MeterView.gap, height: 12)
                Spacer(minLength: 8)
                Text(model.level <= -60 ? "-inf dB" : "\(Int(model.level.rounded())) dB")
                    .font(.mono(12))
                    .foregroundStyle(Color.mutedFg)
            }
        }
        .frame(height: 20)
    }
}

// MARK: - Sidebar

struct CommandRow: View {
    let phrase: String
    let effect: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(phrase)
                    .font(.mono(12, .medium))
                    .foregroundStyle(Color.fg)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(hover && enabled ? Color.accent : Color.muted)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(hover && enabled ? Color.zone : Color.line))
                Spacer(minLength: 0)
                Text(effect).font(.geist(12)).foregroundStyle(hover && enabled ? Color.fg : Color.mutedFg)
            }
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

struct Sidebar: View {
    @Bindable var model: Model

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                section {
                    FieldLabel(title: "Camera", key: "V")
                    Select(id: "video", icon: "video", value: model.videoDev?.localizedName ?? "No camera",
                           options: model.videoDevices.map { ($0.uniqueID, $0.localizedName) },
                           selected: model.videoDev?.uniqueID, onPick: model.selectVideo, model: model)
                }

                section {
                    FieldLabel(title: "Microphone", key: "A")
                    Select(id: "audio", icon: model.micDenied ? "mic.slash" : "mic",
                           value: model.micDenied ? "Microphone access is off" : model.audioDev?.localizedName ?? "No microphone",
                           options: model.audioDevices.map { ($0.uniqueID, $0.localizedName) },
                           selected: model.audioDev?.uniqueID, onPick: model.selectAudio, model: model)
                    MeterView(model: model)
                }

                divider

                section {
                    HStack(spacing: 8) {
                        Text("Format").font(.geist(13)).foregroundStyle(Color.mutedFg).fixedSize()
                        Spacer(minLength: 0)
                        Segmented(items: Model.aspects, index: Model.aspects.firstIndex(of: model.aspect) ?? 0) {
                            model.setAspect(Model.aspects[$0])
                        }
                        .frame(width: 176)
                    }
                    HStack(spacing: 8) {
                        Text("Rotation").font(.geist(13)).foregroundStyle(Color.mutedFg).fixedSize()
                        Spacer(minLength: 0)
                        Segmented(items: ["0°", "90°", "180°", "270°"], index: model.turns) { model.setTurns($0) }
                            .frame(width: 176)
                    }
                    HStack(spacing: 8) {
                        Text("Frame rate").font(.geist(13)).foregroundStyle(Color.mutedFg).fixedSize()
                        Spacer(minLength: 0)
                        Segmented(items: ["30", "50", "60"], index: [30, 50, 60].firstIndex(of: model.fps) ?? 0) {
                            model.setFps([30, 50, 60][$0])
                        }
                        .frame(width: 176)
                    }
                }

                divider

                section {
                    HStack(spacing: 8) {
                        Text("Teleprompter").font(.geist(13, .medium)).foregroundStyle(Color.fg)
                        Spacer(minLength: 0)
                        Kbd(key: "T")
                        Switch(on: model.promptVisible) { model.togglePromptVisible() }
                    }
                    .frame(height: 20)
                    Segmented(items: ["Follows voice", "Fixed speed"], index: model.promptMode == .voice ? 0 : 1) {
                        model.setPromptMode($0 == 0 ? .voice : .speed)
                    }
                    HStack(spacing: 8) {
                        OutlineButton(icon: model.promptRunning ? "pause.fill" : "play.fill",
                                      title: model.promptRunning ? "Pause" : "Start", key: "P") {
                            model.togglePrompter()
                        }
                        IconButton(icon: "arrow.up.to.line", help: "Back to the top  (0)") { model.rewindTop() }
                    }
                    // Same rule as the E key: the editor would swallow Space and the spoken commands mid-take.
                    OutlineButton(icon: "text.alignleft", title: model.script.isEmpty ? "Write script" : "Edit script", key: "E") {
                        if !model.recording { model.openSelect = nil; model.editing = true }
                    }
                    .disabled(model.recording)
                    .opacity(model.recording ? 0.4 : 1)
                    StepperRow(title: "Text size", value: "\(Int(model.promptSize))",
                               minus: { model.setPromptSize(model.promptSize - 2) }, plus: { model.setPromptSize(model.promptSize + 2) })
                    if model.promptMode == .speed {
                        StepperRow(title: "Speed", value: "\(Int(model.speed))",
                                   minus: { model.setSpeed(model.speed - 4) }, plus: { model.setSpeed(model.speed + 4) })
                        StepperRow(title: "Delay", value: String(format: "%.1f s", model.promptDelay),
                                   minus: { model.setPromptDelay(model.promptDelay - 0.5) }, plus: { model.setPromptDelay(model.promptDelay + 0.5) })
                    }
                }

                divider

                section {
                    HStack(spacing: 8) {
                        Text("Voice commands").font(.geist(13, .medium)).foregroundStyle(Color.fg)
                        Spacer(minLength: 0)
                        Switch(on: model.voiceCommands) { model.toggleVoiceCommands() }
                    }
                    .frame(height: 20)
                    CommandRow(phrase: "take start", effect: "Count in, record", enabled: model.applies(.start)) { model.trigger(.start) }
                    CommandRow(phrase: "take again", effect: "Discard, record again", enabled: model.applies(.again)) { model.trigger(.again) }
                    CommandRow(phrase: "take end", effect: "Stop, keep", enabled: model.applies(.end)) { model.trigger(.end) }
                    CommandRow(phrase: "take reset", effect: "Teleprompter from the top", enabled: model.applies(.reset)) { model.trigger(.reset) }
                    HStack(spacing: 8) {
                        Text("Keep take end in the take").font(.geist(13)).foregroundStyle(Color.mutedFg).fixedSize()
                        Spacer(minLength: 0)
                        Switch(on: model.keepEnd) { model.toggleKeepEnd() }
                    }
                    .frame(height: 20)
                    .padding(.top, 2)
                }

                divider

                section {
                    FieldLabel(title: "Save to", key: "O")
                    Button { model.chooseFolder() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.onExternal ? "externaldrive" : "folder")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.mutedFg).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.folderName).font(.geist(13, .medium)).foregroundStyle(Color.fg).lineLimit(1)
                                Text(model.folderPath).font(.geist(12)).foregroundStyle(Color.subtle).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            Text("Change").font(.geist(12, .medium)).foregroundStyle(Color.mutedFg)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(Color.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 6) {
                        Text("Next").font(.geist(12)).foregroundStyle(Color.subtle)
                        Text(model.fileName(model.take)).font(.mono(12)).foregroundStyle(Color.mutedFg).lineLimit(1)
                        Spacer(minLength: 0)
                        Button { model.revealFolder() } label: {
                            Image(systemName: "arrow.up.forward.square").font(.system(size: 12)).foregroundStyle(Color.mutedFg)
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                    }
                }

                divider

                section {
                    HStack(spacing: 8) {
                        Text("Check for updates").font(.geist(13)).foregroundStyle(Color.mutedFg).fixedSize()
                        Spacer(minLength: 0)
                        Switch(on: model.updateCheck) { model.toggleUpdateCheck() }
                    }
                    .frame(height: 20)
                    if let v = model.updateAvailable {
                        Button { model.openUpdatePage() } label: {
                            HStack(spacing: 6) {
                                Text("take \(v) is out").font(.geist(12, .medium)).foregroundStyle(Color.fg)
                                Spacer(minLength: 0)
                                Text("take.ante.design").font(.geist(12)).foregroundStyle(Color.mutedFg)
                                Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.mutedFg)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(model.updateCheck ? "Asks take.ante.design once a day. Version \(Updater.currentVersion)." : "Off: take makes no network requests. Version \(Updater.currentVersion).")
                            .font(.geist(12)).foregroundStyle(Color.subtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.card)
        .overlay(alignment: .leading) { Rectangle().fill(Color.line).frame(width: 1) }
    }

    private var divider: some View {
        Rectangle().fill(Color.line).frame(height: 1).padding(.vertical, 6)
    }

    private func section<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
    }
}


// MARK: - Logo

/// The logo: the record square, then TAKE, drawn on the TFC Bit Neue grid (7 rows of square dots) so it is
/// sharp on retina: letters and square exactly 10 pt, the cap height of the Geist 14 beside it.
/// Dots 1 pt (2 px), rows 1.5 pt apart. Same drawing as the site's logo.svg, one size down.
struct Logo: View {
    static let size = CGSize(width: 50, height: 10)
    static let square = CGRect(x: 0, y: 0, width: 10, height: 10)
    static let letters: [CGRect] = [
        CGRect(x: 16, y: 0, width: 7, height: 1),
        CGRect(x: 19, y: 1.5, width: 1, height: 1),
        CGRect(x: 19, y: 3, width: 1, height: 1),
        CGRect(x: 19, y: 4.5, width: 1, height: 1),
        CGRect(x: 19, y: 6, width: 1, height: 1),
        CGRect(x: 19, y: 7.5, width: 1, height: 1),
        CGRect(x: 19, y: 9, width: 1, height: 1),
        CGRect(x: 26.5, y: 0, width: 4, height: 1),
        CGRect(x: 25, y: 1.5, width: 1, height: 1),
        CGRect(x: 25, y: 3, width: 1, height: 1),
        CGRect(x: 25, y: 6, width: 1, height: 1),
        CGRect(x: 25, y: 7.5, width: 1, height: 1),
        CGRect(x: 25, y: 9, width: 1, height: 1),
        CGRect(x: 25, y: 4.5, width: 7, height: 1),
        CGRect(x: 31, y: 3, width: 1, height: 1),
        CGRect(x: 31, y: 6, width: 1, height: 1),
        CGRect(x: 31, y: 7.5, width: 1, height: 1),
        CGRect(x: 31, y: 9, width: 1, height: 1),
        CGRect(x: 31, y: 1.5, width: 1, height: 1),
        CGRect(x: 34, y: 0, width: 1, height: 1),
        CGRect(x: 34, y: 1.5, width: 1, height: 1),
        CGRect(x: 34, y: 3, width: 1, height: 1),
        CGRect(x: 34, y: 6, width: 1, height: 1),
        CGRect(x: 34, y: 7.5, width: 1, height: 1),
        CGRect(x: 34, y: 9, width: 1, height: 1),
        CGRect(x: 38.5, y: 3, width: 1, height: 1),
        CGRect(x: 39, y: 1.5, width: 1, height: 1),
        CGRect(x: 40, y: 0, width: 1, height: 1),
        CGRect(x: 39, y: 7.5, width: 1, height: 1),
        CGRect(x: 40, y: 9, width: 1, height: 1),
        CGRect(x: 38.5, y: 6, width: 1, height: 1),
        CGRect(x: 34, y: 4.5, width: 5, height: 1),
        CGRect(x: 43, y: 0, width: 7, height: 1),
        CGRect(x: 43, y: 1.5, width: 1, height: 1),
        CGRect(x: 43, y: 3, width: 1, height: 1),
        CGRect(x: 43, y: 6, width: 1, height: 1),
        CGRect(x: 43, y: 7.5, width: 1, height: 1),
        CGRect(x: 43, y: 4.5, width: 5.5, height: 1),
        CGRect(x: 43, y: 9, width: 7, height: 1)
    ]
    var body: some View {
        Canvas { ctx, _ in
            ctx.fill(Path(Logo.square), with: .color(.danger))
            var p = Path()
            for r in Logo.letters { p.addRect(r) }
            ctx.fill(p, with: .color(.fg))
        }
        .frame(width: Logo.size.width, height: Logo.size.height)
        .accessibilityElement()
        .accessibilityLabel("take")
        .accessibilityAddTraits(.isImage)
    }
}

// MARK: - Header

/// Behaves like a real title bar: drag to move, double-click follows the system setting (zoom or minimise).
final class TitleBarZone: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with e: NSEvent) {
        guard let w = window else { return }
        if e.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
            case "Minimize": w.performMiniaturize(nil)
            case "None": break
            default: w.performZoom(nil)
            }
        } else {
            w.performDrag(with: e)
        }
    }
}

struct TitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarZone { TitleBarZone() }
    func updateNSView(_ v: TitleBarZone, context: Context) {}
}

struct Header: View {
    @Bindable var model: Model

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                Logo()
                Text("/").font(.geist(14)).foregroundStyle(Color.zone).accessibilityHidden(true)
                Text("Take \(String(format: "%02d", model.take))").font(.geist(14, .medium)).foregroundStyle(Color.mutedFg)
                Spacer()
                if model.listening {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.ok)
                        Text("Listening").font(.geist(12, .medium)).foregroundStyle(Color.mutedFg)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .overlay(Capsule().strokeBorder(Color.line))
                }
                if model.frameSize != .zero {
                    Badge(text: "\(Int(model.frameSize.width)) × \(Int(model.frameSize.height))")
                }
                Badge(text: "\(model.liveFps ?? model.fps) fps")
                Badge(text: "HEVC")
            }
            status
        }
        .padding(.leading, 84)
        .padding(.trailing, 24)
        .frame(height: 52)
        .background(TitleBar())
        .background(Color.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }

    private var status: some View {
        let label = model.recording ? "Recording" : model.hasSignal ? "Ready" : "No signal"
        let color: Color = model.recording ? .danger : model.hasSignal ? .ok : .warn
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.geist(12, .medium)).foregroundStyle(model.recording ? Color.danger : Color.fg)
            if model.recording {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    Text(Timecode.string(model.recStart)).font(.mono(12, .medium)).foregroundStyle(Color.danger)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(model.recording ? Color.danger.opacity(0.12) : Color.muted)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(model.recording ? Color.danger.opacity(0.35) : Color.line))
    }
}

// MARK: - Script dialog

struct ScriptDialog: View {
    @Bindable var model: Model
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).onTapGesture { cancel() }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Script").font(.geist(18, .semibold)).foregroundStyle(Color.fg)
                    Text("Shown over the camera while you record. Only you see it.")
                        .font(.geist(13)).foregroundStyle(Color.mutedFg)
                }
                TextEditor(text: $text)
                    .font(.geist(14))
                    .lineSpacing(4)
                    .foregroundStyle(Color.fg)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.line))
                    .frame(height: 300)
                    .focused($focused)
                HStack(spacing: 8) {
                    Text("\(text.split { $0.isWhitespace }.count) words").font(.geist(12)).foregroundStyle(Color.subtle)
                    Spacer()
                    Button { cancel() } label: {
                        HStack(spacing: 8) { Text("Cancel").font(.geist(13, .medium)); Kbd(key: "Esc") }
                            .foregroundStyle(Color.fg)
                            .padding(.leading, 14).padding(.trailing, 8)
                            .frame(height: 36)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.line))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { save() } label: {
                        HStack(spacing: 8) { Text("Save").font(.geist(13, .semibold)); Kbd(key: "⌘↩", dark: true) }
                            .foregroundStyle(Color.bg)
                            .padding(.leading, 14).padding(.trailing, 8)
                            .frame(height: 36)
                            .background(Color.fg)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .frame(width: 560)
            .background(Color.bg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.line))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
        }
        .onAppear { text = model.script; focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .saveScript)) { _ in save() }
    }

    func save() { model.setScript(text); model.editing = false }
    func cancel() { model.editing = false }
}

// MARK: - Toast view

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.tone == .good ? "checkmark.circle.fill" : toast.tone == .bad ? "exclamationmark.circle.fill" : "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(toast.tone == .good ? Color.ok : toast.tone == .bad ? Color.danger : Color.mutedFg)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title).font(.geist(13, .medium)).foregroundStyle(Color.fg)
                if !toast.detail.isEmpty {
                    Text(toast.detail).font(.geist(12)).foregroundStyle(Color.mutedFg).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(Color.bg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }
}

// MARK: - Root

struct RootView: View {
    @Bindable var model: Model

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)
            HStack(spacing: 0) {
                GeometryReader { g in
                    let availH = g.size.height - 40 - 24 - 64
                    let availW = g.size.width - 64
                    let r = model.ratio.width / model.ratio.height
                    let h = max(160, floor(min(availH, availW / r) / 2) * 2)
                    VStack(spacing: 24) {
                        Preview(model: model, size: CGSize(width: floor(h * r / 2) * 2, height: h))
                        RecordButton(model: model)
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
                .background(Color.bg)
                Sidebar(model: model)
            }
        }
        .background(Color.bg)
        .overlay(alignment: .bottomLeading) {
            if let t = model.toast {
                ToastView(toast: t)
                    .padding(24)
                    .transition(.opacity.combined(with: .offset(y: 8)))
                    .id(t.id)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.toast)
        .overlayPreferenceValue(SelectAnchorKey.self) { anchors in
            GeometryReader { g in
                if let id = model.openSelect, let a = anchors[id], let menu = model.selectMenu, menu.id == id {
                    let r = g[a]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).onTapGesture { model.openSelect = nil }
                        DropdownList(menu: menu, model: model)
                            .frame(width: r.width)
                            .offset(x: r.minX, y: r.maxY + 6)
                    }
                }
            }
        }
        .overlay { if model.editing { ScriptDialog(model: model) } }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    let model = Model()
    private var monitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        registerFonts()
        buildMenu()

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "take"
        w.backgroundColor = NSColor(red: 9 / 255, green: 9 / 255, blue: 11 / 255, alpha: 1)
        w.appearance = NSAppearance(named: .darkAqua)
        // Fits a 13-inch MacBook at 1440 x 900 with the Dock showing (about 810 pt usable). The sidebar scrolls below that.
        w.minSize = NSSize(width: 1000, height: 680)
        w.contentView = NSHostingView(rootView: RootView(model: model))
        w.setFrameAutosaveName("take-v2")
        if !w.setFrameUsingName("take-v2") { w.center() }
        fitOnScreen(w)
        w.makeKeyAndOrderFront(nil)
        window = w
        placeTrafficLights()
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in self?.placeTrafficLights() }
        }
        NSApp.activate(ignoringOtherApps: true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] e in
            guard let self else { return e }
            return self.handle(e)
        }

        AVCaptureDevice.requestAccess(for: .video) { v in
            AVCaptureDevice.requestAccess(for: .audio) { a in
                DispatchQueue.main.async { self.model.start(camera: v, mic: a) }
            }
        }
    }

    /// Keeps the whole window, title bar and record button included, inside the usable part of its screen.
    private func fitOnScreen(_ w: NSWindow) {
        guard let vf = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = w.frame
        f.size.width = min(f.width, vf.width)
        f.size.height = min(f.height, vf.height)
        f.origin.x = min(max(f.minX, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        if f != w.frame { w.setFrame(f, display: false) }
    }

    /// Centres the window buttons on the 52 pt header.
    private func placeTrafficLights() {
        guard let w = window, !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton), let container = close.superview?.superview else { return }
        let barH: CGFloat = 52
        container.frame = NSRect(x: 0, y: w.frame.height - barH, width: w.frame.width, height: barH)
        close.superview?.frame = container.bounds
        for (i, t) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = w.standardWindowButton(t) else { continue }
            b.setFrameOrigin(NSPoint(x: 20 + CGFloat(i) * 20, y: floor((barH - b.frame.height) / 2)))
        }
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        // Only the main window. The Save to panel, the About panel and any sheet keep their own keys and scrolling.
        guard e.window === window, NSApp.modalWindow == nil, window.attachedSheet == nil else { return e }
        let m = model
        if e.type == .scrollWheel {
            if !m.editing && m.openSelect == nil { m.scroll(-e.scrollingDeltaY) }
            return e
        }
        if m.editing {
            if e.keyCode == 53 { m.editing = false; return nil }
            if e.keyCode == 36 && e.modifierFlags.contains(.command) {
                NotificationCenter.default.post(name: .saveScript, object: nil)
                return nil
            }
            return e
        }
        if e.modifierFlags.contains(.command) { return e }
        if e.keyCode == 53 { m.openSelect = nil; return nil }
        switch e.keyCode {
        case 49: m.toggleRecord(); return nil
        case 126: m.setSpeed(m.speed + 4); return nil
        case 125: m.setSpeed(m.speed - 4); return nil
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "p": m.togglePrompter()
        case "t": m.togglePromptVisible()
        case "0": m.rewindTop()
        case "+", "=": m.setPromptSize(m.promptSize + 2)
        case "-": m.setPromptSize(m.promptSize - 2)
        case "e": if !m.recording { m.openSelect = nil; m.editing = true }
        case "r": m.setTurns(m.turns + 1)
        case "s": let f = [30, 50, 60]; m.setFps(f[((f.firstIndex(of: m.fps) ?? -1) + 1) % f.count])
        case "v": m.cycleVideo()
        case "a": m.cycleAudio()
        case "o": m.chooseFolder()
        case "f": window.toggleFullScreen(nil)
        default: return e
        }
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        // Also while a stopped take is still being finished: quitting then leaves a file that never plays.
        guard model.recording || model.saving else { return .terminateNow }
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        model.stopForQuit(reply)
        // A drive that stops answering must not keep take open forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: reply)
        return .terminateLater
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About take", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Visit take.ante.design", action: #selector(visitSite), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide take", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit take", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.control, .command]
        win.addItem(.separator())
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }

    static let site = URL(string: "https://take.ante.design")!

    @objc private func showAbout() {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                   .foregroundColor: NSColor.secondaryLabelColor,
                                                   .paragraphStyle: p]
        let credits = NSMutableAttributedString(string: "Made with Claude Code. ", attributes: base)
        var link = base
        link[.link] = App.site
        credits.append(NSAttributedString(string: "take.ante.design", attributes: link))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// The only network-facing call in take: the user picks it from the menu, the default browser opens the page.
    @objc private func visitSite() { NSWorkspace.shared.open(App.site) }
}

extension Notification.Name { static let saveScript = Notification.Name("take.saveScript") }

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
