import SwiftUI
import AppKit
import Speech
import AVFoundation
import CoreAudio
import Combine
import ServiceManagement

// ─────────────────────────────────────────
// MARK: - App Entry Point
// ─────────────────────────────────────────
@main
struct GhostPilot: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

// ─────────────────────────────────────────
// MARK: - Visual Effect View (fixes black bg)
// ─────────────────────────────────────────
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// ─────────────────────────────────────────
// MARK: - App Delegate
// ─────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem?
    var popupWindow: NSWindow?
    var globalKeyMonitor: Any?
    var localKeyMonitor: Any?

    // Normal (compact) and expanded sizes
    static let compactSize = NSSize(width: 860, height: 520)
    static let fullSize    = NSSize(width: 860, height: 700)

    let shortcutKey: String                      = "h"
    let shortcutModifiers: NSEvent.ModifierFlags = [.command, .shift]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? SMAppService.mainApp.register()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "eye.slash.fill",
                                   accessibilityDescription: "Hidden Popup")
            button.action = #selector(togglePopup)
            button.target = self
        }
        registerGlobalHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor  { NSEvent.removeMonitor(m) }
    }

    func registerGlobalHotkey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            let chars = event.charactersIgnoringModifiers?.lowercased()
            let mod   = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == self.shortcutModifiers
            if mod {
                if chars == self.shortcutKey {
                    DispatchQueue.main.async { self.togglePopup() }
                } else if chars == "s" {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .triggerScreenCapture, object: nil)
                    }
                }
            }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localKeyMonitor  = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in handler(e); return e }
    }

    @objc func togglePopup() {
        if let win = popupWindow, win.isVisible { win.orderOut(nil); return }
        showPopup()
    }

    func showPopup() {
        let sz = AppDelegate.compactSize
        let hostingView = ClickThroughHostingView(rootView: PopupView(
            onClose: { [weak self] in self?.popupWindow?.orderOut(nil) },
            onToggleFullScreen: { [weak self] in self?.toggleWindowSize() }
        ))
        hostingView.setFrameSize(NSSize(width: sz.width, height: sz.height))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: sz),
            styleMask:   [.borderless, .resizable],
            backing:     .buffered,
            defer:       false
        )
        window.sharingType               = .none
        window.contentView               = hostingView
        window.isOpaque                  = false
        window.backgroundColor           = .clear
        window.level                     = .floating
        window.hasShadow                 = true
        // Fix 1: allow dragging from any non-button background area
        window.isMovableByWindowBackground = true
        // Fix 1: prevent collapsing to nothing when resizing
        window.minSize = NSSize(width: 380, height: 260)

        // Center on screen
        if let screen = NSScreen.main {
            let sx = (screen.frame.width  - sz.width)  / 2
            let sy = (screen.frame.height - sz.height) / 2
            window.setFrameOrigin(NSPoint(x: screen.frame.minX + sx,
                                          y: screen.frame.minY + sy))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        popupWindow = window
    }

    /// Toggle between compact and full-screen-spanning sizes
    func toggleWindowSize() {
        guard let win = popupWindow, let screen = NSScreen.main else { return }
        let isExpanded = win.frame.width >= screen.frame.width - 10
        if isExpanded {
            let sz = AppDelegate.compactSize
            let sx = (screen.frame.width  - sz.width)  / 2
            let sy = (screen.frame.height - sz.height) / 2
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                win.animator().setFrame(
                    NSRect(x: screen.frame.minX + sx, y: screen.frame.minY + sy,
                           width: sz.width, height: sz.height),
                    display: true
                )
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                win.animator().setFrame(screen.frame, display: true)
            }
        }
    }
}

extension NSNotification.Name {
    static let triggerScreenCapture = NSNotification.Name("TriggerScreenCapture")
}

// ─────────────────────────────────────────
// MARK: - Click-through hosting view
// The toolbar (top ~90 pts in SwiftUI = HIGH y-values in AppKit) always
// receives events so all buttons work. The transparent content area below
// returns nil from hitTest so clicks fall through to underlying windows.
// ─────────────────────────────────────────
final class ClickThroughHostingView: NSHostingView<AnyView> {
    convenience init<V: View>(rootView: V) {
        self.init(rootView: AnyView(rootView))
    }
    override var isOpaque: Bool { false }

    // Height of toolbar + marquee strip in SwiftUI points.
    // AppKit y=0 is at BOTTOM, so this zone is at the TOP of the window
    // = y values >= (bounds.height - interactiveHeight).
    private let interactiveHeight: CGFloat = 92

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point is in the view’s own coordinate space (y=0 at bottom).
        let inToolbar = point.y >= (bounds.height - interactiveHeight)
        if inToolbar {
            // Toolbar zone — use normal SwiftUI hit testing so every button works.
            return super.hitTest(point)
        }
        // Content / transparent zone — pass clicks through to underlying windows.
        return nil
    }
}

// ─────────────────────────────────────────
// MARK: - Realtime Manager (WebSocket)
// ─────────────────────────────────────────
class RealtimeManager: NSObject, ObservableObject {
    @Published var aiResponse: String    = ""
    @Published var isConnected: Bool     = false
    @Published var isResponding: Bool    = false

    // ⚠️ Replace with your actual key — never ship in plain text, use a secure env var
    let apiKey = "YOUR_API_KEY_HERE"

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var accumulatedText: String = ""

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
    }

    // MARK: Connect
    func connect() {
        guard !apiKey.contains("YOUR_API_KEY") else {
            DispatchQueue.main.async { self.aiResponse = "❌ Set your OpenAI API key in source." }
            return
        }

        var request = URLRequest(
            url: URL(string: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview-2024-10-01")!
        )
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("realtime=v1",       forHTTPHeaderField: "OpenAI-Beta")

        webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask?.resume()

        // Configure the session right after connecting
        sendEvent([
            "type": "session.update",
            "session": [
                "modalities":           ["text"],   // text-only output; add "audio" for TTS
                "instructions":         "You are a technical interview copilot. The user is in a live interview. Provide extremely concise, smart bullet-point answers or hints. Keep responses short and practical.",
                "input_audio_format":   "pcm16",
                "output_audio_format":  "pcm16",
                "input_audio_transcription": ["model": "whisper-1"],
                "turn_detection": [
                    "type":                "server_vad",
                    "threshold":           0.5,
                    "prefix_padding_ms":   300,
                    "silence_duration_ms": 800
                ]
            ] as [String: Any]
        ])

        DispatchQueue.main.async { self.isConnected = true }
        receiveLoop()
    }

    // MARK: Disconnect
    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        DispatchQueue.main.async {
            self.isConnected  = false
            self.isResponding = false
        }
    }

    // MARK: Stream raw PCM16 audio (base64) — called per audio tap buffer
    func sendAudio(_ base64PCM16: String) {
        sendEvent(["type": "input_audio_buffer.append", "audio": base64PCM16])
    }

    // MARK: Send a plain text turn (used when silence is detected from transcript)
    func sendTextTurn(_ text: String) {
        sendEvent([
            "type": "conversation.item.create",
            "item": [
                "type":    "message",
                "role":    "user",
                "content": [["type": "input_text", "text": text]]
            ] as [String: Any]
        ])
        sendEvent(["type": "response.create"])
    }

    // MARK: Analyze screenshot — Realtime API doesn't support images, so we use Chat API
    func analyzeScreenshot(base64Image: String, context: String) {
        guard !apiKey.contains("YOUR_API_KEY") else { return }
        DispatchQueue.main.async {
            self.aiResponse   = "🔍 Analyzing screen..."
            self.isResponding = true
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let userContent: [[String: Any]] = [
            ["type": "text",
             "text": context.isEmpty ? "What is shown in this image? Give concise interview hints." : context],
            ["type": "image_url",
             "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]]
        ]

        let body: [String: Any] = [
            "model":    "gpt-4o",
            "messages": [
                ["role": "system", "content": "You are a technical interview copilot. Give extremely concise bullet-point answers. Max 5 bullets."],
                ["role": "user",   "content": userContent]
            ],
            "max_tokens": 400
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.isResponding = false
                if let error = error {
                    self?.aiResponse = "❌ \(error.localizedDescription)"; return
                }
                guard let data = data,
                      let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let msg     = choices.first?["message"] as? [String: Any],
                      let content = msg["content"] as? String else {
                    self?.aiResponse = "❌ Failed to parse response."; return
                }
                self?.aiResponse = content
            }
        }.resume()
    }

    // MARK: Internal helpers
    private func sendEvent(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str  = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(str)) { error in
            if let e = error { print("WS send error: \(e)") }
        }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.handleServerEvent(text) }
                self.receiveLoop()     // keep reading
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isConnected  = false
                    self.isResponding = false
                    if !error.localizedDescription.contains("cancelled") {
                        self.aiResponse = "⚠️ Disconnected: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func handleServerEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        DispatchQueue.main.async {
            switch type {

            // ── Streaming text delta ──
            case "response.text.delta":
                let delta = (obj["delta"] as? String) ?? ""
                self.accumulatedText += delta
                self.aiResponse   = self.accumulatedText
                self.isResponding = true

            // ── Text turn complete ──
            case "response.text.done":
                self.accumulatedText = ""
                self.isResponding    = false

            // ── Transcription from audio input (VAD path) ──
            case "conversation.item.input_audio_transcription.completed":
                let transcript = (obj["transcript"] as? String) ?? ""
                print("📝 Whisper transcript: \(transcript)")

            // ── Full response done ──
            case "response.done":
                self.isResponding = false

            // ── Server-side VAD detected speech start ──
            case "input_audio_buffer.speech_started":
                self.isResponding = false
                self.accumulatedText = ""

            // ── Errors ──
            case "error":
                let errObj = obj["error"] as? [String: Any]
                self.aiResponse   = "❌ \(errObj?["message"] as? String ?? "Unknown error")"
                self.isResponding = false

            default:
                break
            }
        }
    }
}

// ─────────────────────────────────────────
// MARK: - Speech Manager
// ─────────────────────────────────────────
class SpeechManager: ObservableObject {
    @Published var transcribedText: String = "Tap Listen to start..."
    @Published var isListening: Bool       = false
    @Published var inputSource: String     = "Unknown"

    // Injected so audio can be forwarded to Realtime
    var realtimeManager: RealtimeManager?

    private var silenceTimer: Timer?
    private var lastSentTextLength: Int = 0
    private let audioEngine    = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    // MARK: Find BlackHole device
    private func findBlackHoleDeviceID() -> AudioDeviceID? {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize)
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &devices)

        for deviceID in devices {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            var nameRef: CFString? = nil
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            let status = withUnsafeMutablePointer(to: &nameRef) {
                AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, $0)
            }
            if status == noErr, let name = nameRef as String?, name.lowercased().contains("blackhole") {
                return deviceID
            }
        }
        return nil
    }

    // MARK: Permissions
    func requestPermissionsAndStart() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                DispatchQueue.main.async { self?.transcribedText = "❌ Speech recognition denied." }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { self?.startListening() }
                    else       { self?.transcribedText = "❌ Microphone access denied." }
                }
            }
        }
    }

    // MARK: Start
    func startListening() {
        stopListening()

        guard let blackHoleID = findBlackHoleDeviceID() else {
            DispatchQueue.main.async {
                self.transcribedText = "⚠️ BlackHole not found."
                self.inputSource     = "Not found"
            }
            return
        }

        let inputNode = audioEngine.inputNode
        let audioUnit = inputNode.audioUnit!
        var deviceID  = blackHoleID
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0,
                             &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        audioEngine.reset()

        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0 else {
            DispatchQueue.main.async { self.transcribedText = "❌ Invalid audio format from BlackHole." }
            return
        }

        // ── Local speech recognition (for on-screen transcript) ──
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let result = result {
                    let currentText = result.bestTranscription.formattedString
                    self.transcribedText = currentText

                    // On pause: send text turn to Realtime
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                        let newText = String(currentText.dropFirst(self.lastSentTextLength))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if newText.split(separator: " ").count >= 3 {
                            self.realtimeManager?.sendTextTurn(newText)
                            self.lastSentTextLength = currentText.count
                        }
                    }
                }
                if error != nil || result?.isFinal == true { self.stopListening() }
            }
        }

        // ── Audio formats ──
        // Speech recognition needs Float32 @ 16 kHz
        let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1, interleaved: false)!
        // Realtime API needs PCM16 @ 24 kHz
        let realtimeFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: 24000, channels: 1, interleaved: false)!

        let speechConverter   = AVAudioConverter(from: hardwareFormat, to: speechFormat)
        let realtimeConverter = AVAudioConverter(from: hardwareFormat, to: realtimeFormat)

        if hardwareFormat.channelCount > 1 {
            speechConverter?.channelMap   = [0]
            realtimeConverter?.channelMap = [0]
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Feed Float32 → speech recognizer
            if let conv = speechConverter, let req = self.recognitionRequest {
                let fc = AVAudioFrameCount(speechFormat.sampleRate / hardwareFormat.sampleRate * Double(buffer.frameLength))
                if let out = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: fc) {
                    var fed = false
                    conv.convert(to: out, error: nil) { _, s in
                        if fed { s.pointee = .noDataNow; return nil }
                        fed = true; s.pointee = .haveData; return buffer
                    }
                    req.append(out)
                }
            }

            // Feed PCM16 → Realtime WebSocket
            if let conv = realtimeConverter {
                let fc = AVAudioFrameCount(realtimeFormat.sampleRate / hardwareFormat.sampleRate * Double(buffer.frameLength))
                if let out = AVAudioPCMBuffer(pcmFormat: realtimeFormat, frameCapacity: fc) {
                    var fed = false
                    conv.convert(to: out, error: nil) { _, s in
                        if fed { s.pointee = .noDataNow; return nil }
                        fed = true; s.pointee = .haveData; return buffer
                    }
                    if let channelData = out.int16ChannelData {
                        let bytes = Data(bytes: channelData[0],
                                         count: Int(out.frameLength) * MemoryLayout<Int16>.size)
                        self.realtimeManager?.sendAudio(bytes.base64EncodedString())
                    }
                }
            }
        }

        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isListening     = true
                self.inputSource     = "BlackHole 2ch"
                self.transcribedText = "🎙 Listening via BlackHole..."
            }
        } catch {
            DispatchQueue.main.async { self.transcribedText = "❌ Engine failed: \(error.localizedDescription)" }
        }
    }

    // MARK: Stop
    func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        lastSentTextLength = 0
        DispatchQueue.main.async { self.isListening = false }
    }

    func toggle() { isListening ? stopListening() : requestPermissionsAndStart() }
}

// ─────────────────────────────────────────
// MARK: - Screen Capture Helper
// ─────────────────────────────────────────
func captureScreenBase64() -> String? {
    let tempPath = NSTemporaryDirectory() + UUID().uuidString + ".jpg"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments     = ["-x", "-t", "jpg", tempPath]
    do {
        try task.run(); task.waitUntilExit()
        let data = try Data(contentsOf: URL(fileURLWithPath: tempPath))
        try FileManager.default.removeItem(atPath: tempPath)

        if let image = NSImage(data: data) {
            let targetWidth: CGFloat = 1440
            if image.size.width > targetWidth {
                let ratio      = targetWidth / image.size.width
                let targetSize = NSSize(width: targetWidth, height: image.size.height * ratio)
                let newImage   = NSImage(size: targetSize)
                newImage.lockFocus()
                image.draw(in: NSRect(origin: .zero, size: targetSize))
                newImage.unlockFocus()
                if let tiff    = newImage.tiffRepresentation,
                   let bitmap  = NSBitmapImageRep(data: tiff),
                   let compressed = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
                    return compressed.base64EncodedString()
                }
            }
        }
        return data.base64EncodedString()
    } catch { return nil }
}

// ─────────────────────────────────────────
// MARK: - Marquee Text
// ─────────────────────────────────────────
struct MarqueeText: View {
    let text: String
    @State private var offset: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    let speed: CGFloat = 50

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.82))
                .lineLimit(1)
                .fixedSize()
                .background(GeometryReader { inner in
                    Color.clear.onAppear { textWidth = inner.size.width; containerWidth = geo.size.width; startIfNeeded(geo: geo) }
                })
                .offset(x: offset)
        }
        .clipped()
    }

    private func startIfNeeded(geo: GeometryProxy) {
        guard textWidth > geo.size.width else { return }
        offset = geo.size.width
        withAnimation(.linear(duration: Double(textWidth + geo.size.width) / speed).repeatForever(autoreverses: false)) {
            offset = -textWidth
        }
    }
}

// ─────────────────────────────────────────
// MARK: - Toolbar Pill Button
// ─────────────────────────────────────────
struct PillButton: View {
    let icon: String
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(active ? Color(white: 0.08) : .white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(active ? Color.white : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────
// MARK: - Popup View
// ─────────────────────────────────────────
struct PopupView: View {
    var onClose: () -> Void
    var onToggleFullScreen: () -> Void

    @StateObject private var speech   = SpeechManager()
    @StateObject private var realtime = RealtimeManager()

    // Timer
    @State private var elapsedSeconds = 0
    @State private var timerActive    = false
    private let clockTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var timeString: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    // Response history for ‹ › navigation
    @State private var history: [String] = []
    @State private var historyIdx: Int   = -1

    // Collapse marquee strip
    @State private var marqueVisible = true

    // Displayed AI response (may be a historical snapshot)
    private var displayedResponse: String {
        historyIdx >= 0 && historyIdx < history.count ? history[historyIdx] : realtime.aiResponse
    }

    // Parse displayed response
    private var questionText: String {
        let lines = displayedResponse.components(separatedBy: "\n")
        return lines.first(where: { $0.lowercased().hasPrefix("question") || $0.hasPrefix("💬") })
            ?? speech.transcribedText
    }
    private var answerLines: [String] {
        displayedResponse.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty
                   && !$0.lowercased().hasPrefix("question")
                   && !$0.hasPrefix("💬") }
    }

    var body: some View {
        ZStack {
            // ── True see-through: .allowsHitTesting(false) means this Color
            // doesn't claim clicks — they fall through via ClickThroughHostingView. ──
            Color.black.opacity(0.25)
                .allowsHitTesting(false)

            VStack(spacing: 0) {

                // ══════════════════════════════════
                // MARK: Toolbar
                // ══════════════════════════════════
                HStack(spacing: 8) {

                    // App badge
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.12, green: 0.58, blue: 0.33))
                            .frame(width: 30, height: 30)
                        Text("🦜").font(.system(size: 15))
                    }

                    // Gap 4 Fix: standalone mic icon for quick mute
                    iconBtn(speech.isListening ? "mic.slash.fill" : "mic") {
                        speech.toggle()
                        timerActive = speech.isListening
                    }

                    // AI Help → connect/disconnect realtime
                    PillButton(icon: "sparkles", label: "AI Help", active: realtime.isConnected) {
                        realtime.isConnected ? realtime.disconnect() : realtime.connect()
                    }

                    // Analyze Screen → screenshot + vision
                    PillButton(icon: "display", label: "Analyze Screen", active: false) {
                        guard let b64 = captureScreenBase64() else {
                            realtime.aiResponse = "❌ Screen capture failed. Check Screen Recording permissions."
                            return
                        }
                        realtime.analyzeScreenshot(base64Image: b64, context: speech.transcribedText)
                    }

                    // Chat pill → toggle listening & session timer
                    PillButton(icon: speech.isListening ? "stop.circle.fill" : "mic.fill",
                               label: "Chat",
                               active: speech.isListening) {
                        speech.toggle()
                        timerActive = speech.isListening
                    }

                    Spacer()

                    // Session timer badge
                    HStack(spacing: 5) {
                        Circle()
                            .fill(timerActive ? Color.green : Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                        Text(timeString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.1)))

                    // ⋯ Settings placeholder
                    iconBtn("ellipsis") {}

                    // ⇔ Full-screen toggle
                    iconBtn("arrow.up.left.and.arrow.down.right") {
                        onToggleFullScreen()
                    }

                    // ⌄ Collapse / expand marquee strip
                    iconBtn(marqueVisible ? "chevron.up" : "chevron.down") {
                        withAnimation(.easeInOut(duration: 0.2)) { marqueVisible.toggle() }
                    }

                    // ✕ Close
                    iconBtn("xmark") {
                        speech.stopListening()
                        realtime.disconnect()
                        onClose()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.20))

                // ══════════════════════════════════
                // MARK: Marquee strip
                // ══════════════════════════════════
                if marqueVisible {
                    HStack(spacing: 8) {
                        MarqueeText(text: questionText)

                        Spacer()

                        // ‹ previous response
                        iconBtn("chevron.left") {
                            guard history.count > 0 else { return }
                            if historyIdx < 0 { historyIdx = history.count - 1 }
                            else if historyIdx > 0 { historyIdx -= 1 }
                        }

                        // › next response
                        iconBtn("chevron.right") {
                            guard history.count > 0 else { return }
                            if historyIdx < history.count - 1 { historyIdx += 1 }
                            else { historyIdx = -1 }   // back to live
                        }

                        // 🗑 Clear
                        iconBtn("trash") {
                            speech.transcribedText = "Tap Chat to start…"
                            realtime.aiResponse    = ""
                            history.removeAll()
                            historyIdx = -1
                        }

                        // ✕ dismiss / hide strip
                        iconBtn("xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) { marqueVisible = false }
                        }
                    }
                    .frame(height: 34)
                    .padding(.horizontal, 16)
                    .background(Color.black.opacity(0.12))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // ══════════════════════════════════
                // MARK: Content panel  (Gap 2 Fix: inner card with nav + action buttons)
                // ══════════════════════════════════
                ZStack {
                    // ── Card: no fill at all — just a visible border ──
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)

                    // ── Q&A scroll content ──
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {

                            // 💬 Question
                            HStack(alignment: .top, spacing: 10) {
                                Text("💬").font(.system(size: 16))
                                Group {
                                    Text("Question").fontWeight(.heavy)
                                    + Text(": ")
                                    + Text(questionText.isEmpty ? "Listening…" : questionText)
                                        .fontWeight(.semibold)
                                }
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .shadow(color: .black, radius: 4, x: 0, y: 2)
                                .fixedSize(horizontal: false, vertical: true)
                            }

                            // ⭐ Answer
                            HStack(alignment: .top, spacing: 10) {
                                Text("⭐").font(.system(size: 16))
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Answer:").font(.system(size: 14, weight: .heavy))
                                        .foregroundColor(.white)
                                        .shadow(color: .black, radius: 4, x: 0, y: 2)

                                    if answerLines.isEmpty && !realtime.isResponding {
                                        Text("Press AI Help to connect, then Chat to listen…")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.white.opacity(0.55))
                                            .shadow(color: .black, radius: 3)
                                    } else {
                                        ForEach(Array(answerLines.enumerated()), id: \.offset) { _, line in
                                            HStack(alignment: .top, spacing: 7) {
                                                Text("•")
                                                    .foregroundColor(.white)
                                                    .shadow(color: .black, radius: 3)
                                                Text(line
                                                    .trimmingCharacters(in: .whitespaces)
                                                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•·")))
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .shadow(color: .black, radius: 4, x: 0, y: 2)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }

                                    // Gap 3 Fix: system circular spinner instead of custom dots
                                    if realtime.isResponding {
                                        HStack(spacing: 7) {
                                            ProgressView()
                                                .progressViewStyle(.circular)
                                                .scaleEffect(0.6)
                                                .colorScheme(.dark)
                                            Text("Loading…")
                                                .font(.system(size: 12))
                                                .foregroundColor(.white.opacity(0.45))
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                    // ── Left nav arrow ‹  (inside card, vertically centred) ──
                    HStack {
                        Button(action: {
                            guard history.count > 0 else { return }
                            if historyIdx < 0 { historyIdx = history.count - 1 }
                            else if historyIdx > 0 { historyIdx -= 1 }
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 16)

                        Spacer()

                        // ── Right nav arrow › ──
                        Button(action: {
                            guard history.count > 0 else { return }
                            if historyIdx < history.count - 1 { historyIdx += 1 }
                            else { historyIdx = -1 }  // back to live
                        }) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                    }

                    // ── Trash 🗑 + ✕ anchored to top-right of card ──
                    VStack {
                        HStack {
                            Spacer()
                            iconBtn("trash") {
                                speech.transcribedText = "Tap Chat to start…"
                                realtime.aiResponse    = ""
                                history.removeAll()
                                historyIdx = -1
                            }
                            iconBtn("xmark") {
                                realtime.aiResponse = ""
                                historyIdx = -1
                            }
                        }
                        .padding(.trailing, 14)
                        .padding(.top, 12)
                        Spacer()
                    }
                // ── Resize grip — bottom-right corner ──
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 9, weight: .light))
                                .foregroundColor(.white.opacity(0.30))
                                .padding(8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 12)
        .onAppear { speech.realtimeManager = realtime }
        .onReceive(clockTick) { _ in if timerActive { elapsedSeconds += 1 } }
        // Archive each completed AI response into history
        .onChange(of: realtime.isResponding) { responding in
            if !responding && !realtime.aiResponse.isEmpty {
                if history.last != realtime.aiResponse {
                    history.append(realtime.aiResponse)
                }
                historyIdx = -1   // reset to live view
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerScreenCapture)) { _ in
            guard let base64 = captureScreenBase64() else {
                realtime.aiResponse = "❌ Screen capture failed. Check Screen Recording permissions."
                return
            }
            realtime.analyzeScreenshot(base64Image: base64, context: speech.transcribedText)
        }
    }

    // Compact icon-only button helper
    @ViewBuilder
    private func iconBtn(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
    }
}
