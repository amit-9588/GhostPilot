import SwiftUI
import AppKit
import Speech
import AVFoundation
import CoreAudio
import Combine
import Speech

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
    var keyMonitor: Any?

    let shortcutKey: String                      = "h"
    let shortcutModifiers: NSEvent.ModifierFlags = [.command, .shift]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    }

    func registerGlobalHotkey() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            let keyMatch      = event.charactersIgnoringModifiers == self.shortcutKey
            let modifierMatch = event.modifierFlags
                                     .intersection(.deviceIndependentFlagsMask) == self.shortcutModifiers
            if keyMatch && modifierMatch {
                DispatchQueue.main.async { self.togglePopup() }
            }
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
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
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
            let y        = screen.frame.maxY - 28 - 460
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
            DispatchQueue.main.async {
                if let result = result {
                    self?.transcribedText = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self?.stopListening()
                }
            }
        }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            DispatchQueue.main.async { self.transcribedText = "❌ Could not create converter." }
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self = self, let request = self.recognitionRequest else { return }

            print("🔊 Got tap buffer: \(buffer.frameLength) frames")

            let frameCount = AVAudioFrameCount(targetFormat.sampleRate / hardwareFormat.sampleRate * Double(buffer.frameLength))
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if error == nil { request.append(converted) }
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
        DispatchQueue.main.async { self.isListening = false }
    }

    func toggle() {
        isListening ? stopListening() : requestPermissionsAndStart()
    }
}
// ─────────────────────────────────────────
// MARK: - Popup UI
// ─────────────────────────────────────────
struct PopupView: View {
    var onClose: () -> Void

    @StateObject private var speech = SpeechManager()

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
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(10)

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
        .frame(width: 380, height: 460)
    }
}
