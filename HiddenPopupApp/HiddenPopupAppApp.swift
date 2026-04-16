import SwiftUI
import AppKit
import Speech
import AVFoundation
import CoreAudio
import Combine
import Speech
import ServiceManagement


// ─────────────────────────────────────────
// MARK: - App Entry Point
// ─────────────────────────────────────────
@main
struct HiddenPopupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// ─────────────────────────────────────────
// MARK: - App Delegate
// ─────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem?
    var popupWindow: NSWindow?
    var globalKeyMonitor: Any?
    var localKeyMonitor: Any?

    let shortcutKey: String                      = "h"
    let shortcutModifiers: NSEvent.ModifierFlags = [.command, .shift]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        // Auto-start app continuously when the machine boots
        try? SMAppService.mainApp.register()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "eye.slash.fill",
                                   accessibilityDescription: "Hidden Popup")
            button.action = #selector(togglePopup)
            button.target  = self
        }

        registerGlobalHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = globalKeyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
    }

    func registerGlobalHotkey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            let chars = event.charactersIgnoringModifiers?.lowercased()
            let modifierMatch = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == self.shortcutModifiers
            
            if modifierMatch {
                if chars == self.shortcutKey {
                    DispatchQueue.main.async { self.togglePopup() }
                } else if chars == "s" {
                    DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("TriggerScreenCapture"), object: nil) }
                }
            }
        }
        
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    @objc func togglePopup() {
        if let win = popupWindow, win.isVisible {
            win.orderOut(nil)
            return
        }
        showPopup()
    }

    func showPopup() {
        let hostingView = NSHostingView(rootView: PopupView(onClose: { [weak self] in
            self?.popupWindow?.orderOut(nil)
        }))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 580),
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false
        )

        window.sharingType     = .none   // hidden from screen share
        window.contentView     = hostingView
        window.isOpaque        = false
        window.backgroundColor = .clear
        window.level           = .floating
        window.hasShadow       = true

        if let screen = NSScreen.main,
           let button = statusItem?.button,
           let buttonWindow = button.window {
            let btnFrame = button.convert(button.bounds, to: nil)
            let x        = buttonWindow.frame.minX + btnFrame.minX
            let y        = screen.frame.maxY - 28 - 580
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        popupWindow = window
    }
}

class SpeechManager: ObservableObject {

    @Published var transcribedText: String = "Tap 🎙 to start listening..."
    @Published var isListening: Bool = false
    @Published var inputSource: String = "Unknown"
    
    var onPauseDetected: ((String) -> Void)?
    private var silenceTimer: Timer?
    private var lastSentTextLength: Int = 0

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private func findBlackHoleDeviceID() -> AudioDeviceID? {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize)

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &devices)

        for deviceID in devices {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: CFString? = nil
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            let status = withUnsafeMutablePointer(to: &nameRef) { ptr in
                AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
            }
            if status == noErr, let name = nameRef as String?, name.lowercased().contains("blackhole") {
                print("✅ BlackHole device ID: \(deviceID)")
                return deviceID
            }
        }
        return nil
    }

    func requestPermissionsAndStart() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                DispatchQueue.main.async { self?.transcribedText = "❌ Speech recognition denied." }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { self?.startListening() }
                    else { self?.transcribedText = "❌ Microphone access denied." }
                }
            }
        }
    }

    func startListening() {
        stopListening()

        guard let blackHoleID = findBlackHoleDeviceID() else {
            DispatchQueue.main.async {
                self.transcribedText = "⚠️ BlackHole not found."
                self.inputSource = "Not found"
            }
            return
        }

        // ✅ Set BlackHole on the HAL audio unit BEFORE reset
        let inputNode = audioEngine.inputNode
        let audioUnit = inputNode.audioUnit!

        var deviceID = blackHoleID
        let err = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,   // ← was Input before, Global is correct
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        print(err == noErr ? "✅ Device set on audio unit" : "⚠️ AudioUnit set failed: \(err)")

        audioEngine.reset()

        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        print("🎛 Format after device set: \(hardwareFormat)")

        // ✅ Validate format — if sampleRate is 0, device didn't switch
        guard hardwareFormat.sampleRate > 0 else {
            DispatchQueue.main.async { self.transcribedText = "❌ Invalid audio format from BlackHole." }
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) { [weak self] result, error in
            if let err = error {
                print("❌ Recognition task error: \(err.localizedDescription)")
            }
            if let result = result {
                print("✅ Transcription Update: \(result.bestTranscription.formattedString)")
            }
            
            DispatchQueue.main.async {
                if let result = result {
                    let currentText = result.bestTranscription.formattedString
                    self?.transcribedText = currentText
                    
                    self?.silenceTimer?.invalidate()
                    self?.silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                        let newText = String(currentText.dropFirst(self?.lastSentTextLength ?? 0)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if newText.components(separatedBy: .whitespaces).count >= 3 {
                            self?.onPauseDetected?(newText)
                            self?.lastSentTextLength = currentText.count
                        }
                    }
                }
                if error != nil || result?.isFinal == true {
                    if let err = error {
                        self?.transcribedText += "\n(Err: \(err.localizedDescription))"
                    }
                    self?.stopListening()
                }
            }
        }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            DispatchQueue.main.async { self.transcribedText = "❌ Could not create converter." }
            return
        }
        
        // Ensure conversion works even if channel counts differ (e.g. 2 channels -> 1 channel)
        if hardwareFormat.channelCount > 1 && targetFormat.channelCount == 1 {
            converter.channelMap = [0]
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self = self, let request = self.recognitionRequest else { return }

            // Check if buffer is completely silent
            var isSilent = true
            if let floatData = buffer.floatChannelData, buffer.frameLength > 0 {
                var sumSquares: Float = 0
                for i in 0..<Int(buffer.frameLength) {
                    sumSquares += floatData[0][i] * floatData[0][i]
                }
                if sumSquares > 0.000001 { isSilent = false }
            }
            
            if isSilent {
                print("🔇 Audio buffer is completely SILENT (Make sure to play audio into BlackHole!)")
            } else {
                print("🔊 Got tap buffer: \(buffer.frameLength) frames (ACTIVE AUDIO)")
            }

            let frameCount = AVAudioFrameCount(targetFormat.sampleRate / hardwareFormat.sampleRate * Double(buffer.frameLength))
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            var provided = false
            converter.convert(to: converted, error: &error) { _, outStatus in
                if provided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            
            if let err = error {
                print("❌ Convert error: \(err.localizedDescription)")
            } else {
                request.append(converted)
            }
        }

        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isListening = true
                self.inputSource = "BlackHole 2ch"
                self.transcribedText = "🎙 Listening via BlackHole..."
            }
        } catch {
            DispatchQueue.main.async { self.transcribedText = "❌ Engine failed: \(error.localizedDescription)" }
        }
    }

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
        
        DispatchQueue.main.async {
            self.isListening = false
            self.saveTranscription()
        }
    }
    
    private func saveTranscription() {
        let text = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !text.starts(with: "🎙"),
              !text.starts(with: "❌"),
              !text.starts(with: "⚠️"),
              !text.contains("(Saved file:"), // Prevent double-saving
              text != "Tap 🎙 to start listening..." else { return }
        
        let fileManager = FileManager.default
        guard let desktopURL = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let fileURL = desktopURL.appendingPathComponent("Transcription-\(timestamp).txt")
        
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            print("✅ Saved transcription to \(fileURL.path)")
            self.transcribedText += "\n\n(Saved file: Transcription-\(timestamp).txt)"
        } catch {
            print("❌ Failed to save transcription: \(error)")
        }
    }

    func toggle() {
        isListening ? stopListening() : requestPermissionsAndStart()
    }
}

func captureScreenBase64() -> String? {
    let tempPath = NSTemporaryDirectory() + UUID().uuidString + ".jpg"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-t", "jpg", tempPath]
    
    do {
        try task.run()
        task.waitUntilExit()
        
        let data = try Data(contentsOf: URL(fileURLWithPath: tempPath))
        try FileManager.default.removeItem(atPath: tempPath)
        
        if let image = NSImage(data: data) {
            let targetWidth: CGFloat = 1440
            if image.size.width > targetWidth {
                let ratio = targetWidth / image.size.width
                let targetSize = NSSize(width: targetWidth, height: image.size.height * ratio)
                let newImage = NSImage(size: targetSize)
                newImage.lockFocus()
                image.draw(in: NSRect(origin: .zero, size: targetSize))
                newImage.unlockFocus()
                
                if let tiffRep = newImage.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffRep),
                   let compressed = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
                    return compressed.base64EncodedString()
                }
            }
        }
        return data.base64EncodedString()
    } catch {
        return nil
    }
}

class ChatGPTManager: ObservableObject {
    @Published var aiResponse: String = "ChatGPT is waiting for questions..."
    let apiKey = "YOUR_API_KEY_HERE"
    
    func fetchResponse(for text: String, base64Image: String? = nil) {
        guard !apiKey.contains("YOUR_API_KEY"), !apiKey.isEmpty else {
            DispatchQueue.main.async { self.aiResponse = "❌ Please set your OpenAI API Key in the source code." }
            return
        }
        
        DispatchQueue.main.async { self.aiResponse = "🤔 Thinking..." }
        
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var contentArray: [[String: Any]] = [
            ["type": "text", "text": text.isEmpty ? "What is shown in the image?" : text]
        ]
        
        if let base64Image = base64Image {
            // Append base64 image data payload for GPT-4o Vision
            contentArray.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]
            ])
        }

        let messages: [[String: Any]] = [
            ["role": "system", "content": "You are a technical interview copilot. The user is in an interview. You will receive an audio transcript, a screenshot of the user's screen, or both. Provide extremely concise, smart bullet points answering the questions or giving hints. Keep it very short."],
            ["role": "user", "content": contentArray]
        ]
        
        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 300
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { self.aiResponse = "❌ GPT Error: \(error.localizedDescription)" }
                return
            }
            guard let data = data else { return }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                DispatchQueue.main.async {
                    self.aiResponse = content
                }
            } else {
                DispatchQueue.main.async { self.aiResponse = "❌ Failed to parse ChatGPT response." }
            }
        }.resume()
    }
}

// ─────────────────────────────────────────
// MARK: - Popup UI
// ─────────────────────────────────────────
struct PopupView: View {
    var onClose: () -> Void

    @StateObject private var speech = SpeechManager()
    @StateObject private var chatGPT = ChatGPTManager()

    var body: some View {
        ZStack(alignment: .topTrailing) {

            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)

            VStack(spacing: 14) {

                // ── Header ──
                HStack {
                    Image(systemName: "eye.slash.fill")
                        .foregroundColor(.purple)
                    Text("Hidden from Screen Share")
                        .font(.headline)
                    Spacer()
                }

                // ── Input Source Badge ──
                HStack(spacing: 6) {
                    Circle()
                        .fill(speech.isListening ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text("Input: \(speech.inputSource)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                Divider()

                // ── Transcription Box ──
                ScrollView {
                    Text(speech.transcribedText)
                        .font(.system(size: 14))
                        .foregroundColor(speech.isListening ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .animation(.easeInOut, value: speech.transcribedText)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(10)
                
                // ── Copilot Response Box ──
                ScrollView {
                    Text(chatGPT.aiResponse)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .animation(.easeInOut, value: chatGPT.aiResponse)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                )

                // ── Controls ──
                HStack(spacing: 12) {

                    // Mic toggle button
                    Button(action: { speech.toggle() }) {
                        HStack(spacing: 6) {
                            Image(systemName: speech.isListening ? "stop.circle.fill" : "mic.circle.fill")
                                .font(.system(size: 20))
                            Text(speech.isListening ? "Stop" : "Start")
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(speech.isListening ? Color.red : Color.purple)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    // Clear button
                    Button(action: {
                        speech.transcribedText = "Tap 🎙 to start listening..."
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("Clear")
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }

                // Shortcut reminder
                HStack(spacing: 4) {
                    Text("Toggle popup:")
                        .foregroundColor(.secondary)
                    Text("⌘ + ⇧ + H")
                        .font(.system(.footnote, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(6)
                }
                .font(.footnote)
            }
            .padding(20)

            // Close button
            Button(action: {
                speech.stopListening()
                onClose()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .frame(width: 380, height: 580)
        .onAppear {
            speech.onPauseDetected = { text in
                chatGPT.fetchResponse(for: text)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerScreenCapture"))) { _ in
            guard let base64 = captureScreenBase64() else {
                chatGPT.aiResponse = "❌ Failed to capture screen. Ensure the app has Screen Recording permissions."
                return
            }
            // Passing the currently held transcription context along with the visual image
            chatGPT.aiResponse = "📸 Screen Captured. Analyzing Visuals..."
            chatGPT.fetchResponse(for: speech.transcribedText, base64Image: base64)
        }
    }
}
