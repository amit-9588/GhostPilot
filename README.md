# HiddenPopupApp

HiddenPopupApp is a stealthy, floating macOS "copilot" designed to act as an unobtrusive AI command center. It features a transparent, glass-like UI inspired by professional AI assistants and operates entirely invisibly to screen recording software (e.g., Zoom, OBS, Meet).

---

## 🌟 Key Features

- **Stealth Mode (`sharingType = .none`)**: The window is entirely hidden from screen recorders and screen sharing applications. You can see it, but your audience cannot.
- **Glass UI with Click-Through**: The interface uses a dark, semi-transparent design. The content area is "click-through", meaning clicks pass right through the window to the applications underneath, so it never blocks your workflow. Only the top toolbar remains clickable.
- **Dynamic AI Interaction**:
  - **Chat & Transcribe**: Captures system audio and transcribes it in real-time.
  - **Screen Analysis**: Capture your screen invisibly and send it to the AI for visual context.
  - **Live Responses**: AI responses are streamed in real-time, categorized into Questions and bulleted Answers.
- **Floating Command Center**: 
  - Draggable from anywhere on the background.
  - Resizable with a minimum size constraint.
  - Toggleable full-screen mode to snap across the width of the display.
  - History navigation to cycle through previous AI interactions (`‹` and `›`).

---

## 🚀Guide: Step-by-Step Setup

Follow these steps to get the app running on your Mac.

### Step 1: Install Prerequisites
1. **Install Xcode**: Download and install Xcode from the Mac App Store. This is required to run the code.
2. **Get an OpenAI API Key**: 
   - Go to [OpenAI's platform](https://platform.openai.com/api-keys).
   - Create an account, set up billing, and generate a new secret API key.
3. **Install BlackHole (For Audio Capture)**:
   - Download and install [BlackHole 2ch](https://existential.audio/blackhole/). This allows the app to listen to audio from other apps like Zoom or Chrome.

### Step 2: Configure Your Audio (Crucial for Transcriptions)
To hear audio yourself while the app also listens to it, you must create a "Multi-Output Device" on your Mac:
1. Open the **Audio MIDI Setup** app on your Mac (use Spotlight search <kbd>Cmd</kbd> + <kbd>Space</kbd> to find it).
2. Click the `+` button in the bottom left corner and select **Create Multi-Output Device**.
3. In the list that appears on the right, check the boxes for:
   - Your primary output (e.g., "MacBook Pro Speakers" or your headphones).
   - "BlackHole 2ch".
4. Go to your Mac's **System Settings > Sound** and set your output to the new **Multi-Output Device**.

### Step 3: Run the Project
1. Open the `HiddenPopupApp` folder and double-click `HiddenPopupApp.xcodeproj` to open it in Xcode.
2. In Xcode, locate the file `HiddenPopupAppApp.swift` in the left sidebar and click on it.
3. Find the line that looks like this:
   ```swift
   let apiKey = "YOUR_API_KEY_HERE"
   ```
4. Replace `"YOUR_API_KEY_HERE"` with the OpenAI API key you generated in Step 1.
5. Click the "Play" button (▶) in the top left corner of Xcode (or press <kbd>Cmd</kbd> + <kbd>R</kbd>) to build and run the app.

### Step 4: Grant macOS Permissions
The first time you run the app and try to use its features, macOS will prompt you for permissions. You **must** allow these in System Settings for the app to function:
- **Accessibility**: Required for the global hotkey (`Cmd + Shift + H`) to work from any application.
- **Screen Recording**: Required for the "Analyze Screen" feature to take invisible screenshots.
- **Microphone**: Required to capture your voice and the system audio via BlackHole.

*(If you ever accidentally deny a permission, go to System Settings > Privacy & Security to manually enable them for HiddenPopupApp).*

---

## 🎮 How to Use the App

### Launching the Dashboard
Whenever the app is running in the background, you can bring up the AI Command Center by pressing:
**<kbd>Cmd</kbd> + <kbd>Shift</kbd> + <kbd>H</kbd>**

### Toolbar Controls
The top bar contains all your clickable controls:

- **🦜 Logo / 🎤 Mic Icon**: Quick toggle to mute/unmute the active audio session.
- **✨ AI Help**: Click to connect the WebSocket to the OpenAI Realtime API. You must be connected before you can get AI answers.
- **🖥 Analyze Screen**: Takes an invisible screenshot of what you are currently looking at and sends it to the AI for analysis.
- **💬 Chat**: Toggles speech listening and starts the session timer.

### Navigating the Interface
- **Marquee Strip**: Displays a scrolling ticker of the current question or transcribed text. Can be collapsed using the chevron `^` button.
- **Click-Through Content**: The dark area below the toolbar shows the AI's answers. You can click "through" this area to interact with apps behind the popup.
- **History Navigation**: Hover over the content area and use the `‹` and `›` arrows on the left and right to review past AI responses.
- **Clear**: Click the `🗑` trash icon to clear the current context and reset your history.
- **Move & Resize**: Drag the popup by clicking on any empty background space. Resize it using the tiny `↗` grip icon in the bottom right corner.

---

## 📄 License
This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See the `LICENSE` file for full details.
