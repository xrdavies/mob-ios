# App Store Screenshot Guide

Required device: iPhone 14 Pro Max or iPhone 15 Pro Max (6.7" display, 1290 × 2796 pixels)

## Setup Before Recording

1. **Clean iPhone state:**
   - Full battery or charging
   - Good Wi-Fi signal
   - Time set to 9:41 AM (Apple's standard)
   - Do Not Disturb enabled (no notifications)
   - Airplane mode icons hidden

2. **App setup:**
   - Pair with your office Mac (mobd running)
   - Create test conversations with good demo content
   - Prepare files for transfer demo
   - Have USB device ready (optional)

3. **Content preparation:**
   - Use clear, professional task descriptions
   - Real code or realistic examples
   - Clean desktop on the office Mac

## Screenshot 1: Hero - Chat with AI Agent

**What to show:** Main chat view with Claude Code working on a real task

**Setup:**
- Conversation title: "Build user dashboard"
- Show 3-4 messages in the timeline
- Agent (Claude Code) should have a streaming or completed reply with code
- Show the composer at bottom with keyboard hidden

**Sample conversation:**
```
You: Add a user dashboard page with activity chart and recent items list. Use shadcn/ui components.

Claude: I'll create a user dashboard with an activity chart and recent items. Let me start by reading the existing layout.

[Shows tool use: Read src/app/layout.tsx]

Claude: [Streaming reply with actual code showing the dashboard component]
```

**Caption for App Store:**
"Chat with AI agents on your office computer. Send tasks, get live updates, and guide the work from anywhere."

---

## Screenshot 2: Live Desktop View

**What to show:** The office Mac's desktop streaming in real-time

**Setup:**
- Start live view from chat or the view icon
- Show a clean, professional desktop
- Have a code editor (VS Code or Xcode) visible with a real project
- Clear enough to see it's a real desktop, but text doesn't need to be readable
- Show the quality selector (Low/Medium/High) if visible

**Desktop should show:**
- Code editor with a file open
- Terminal window (optional)
- Clean desktop background
- No sensitive information

**Caption:**
"See your office computer's screen in real-time. Control quality from your phone to save bandwidth."

---

## Screenshot 3: Agent Collaboration

**What to show:** Timeline with @mentions and agent collaboration requests

**Setup:**
- Conversation showing @api or @backend mentioned in a message
- Show the collaboration chip/indicator
- Request status visible (e.g., "handling" or "replied")
- Timeline includes both your messages and agent's work

**Sample:**
```
You: @api please implement the /users endpoint with pagination

[Collaboration indicator: Request sent to @api]

@api: I'll implement the /users endpoint. Let me check the existing API structure.

[Shows the agent's implementation work]
```

**Caption:**
"Delegate work between AI agents with @mentions. Track requests and see when each agent finishes."

---

## Screenshot 4: File Transfers

**What to show:** File upload/download interface with active transfer

**Setup:**
- Files tab showing transfer in progress
- At least one completed transfer
- Show file names, sizes, and progress bars
- Include both upload and download if possible

**Sample files:**
- design-mockup.png (uploading, 45%)
- database-backup.sql (downloaded, complete)
- api-docs.pdf (queued or in progress)

**Caption:**
"Transfer files between your phone and office computer. Upload images, download builds, with pause and resume."

---

## Screenshot 5: USB Device Sharing

**What to show:** USB device selection dialog

**Setup:**
- Settings → USB (or from chat if there's a USB action)
- Show the USB device list with 1-2 devices
- Devices like "Arduino Uno", "STM32 Dev Board", or "USB Serial Adapter"
- Show clear device names and status

**Caption:**
"Share USB devices from your office to remote computers. Debug hardware, flash firmware, access serial ports."

---

## Screenshot 6: Multiple Machines

**What to show:** Settings screen showing multiple office computers

**Setup:**
- Settings → Machines
- Show 2-3 machines with clear names
- Each showing connection status (online/offline)
- Active machine indicated

**Sample machines:**
- "Office Mac Studio" (active, online)
- "Lab Linux Workstation" (offline)
- "Home iMac" (online)

**Caption:**
"Connect multiple office computers. Switch between them instantly, each with its own chats and desktop."

---

## Screenshot 7: Request Details & Cancel

**What to show:** Collaboration request detail sheet with "Cancel and stop its turn" button

**Setup:**
- Open a request from collaboration tab
- Show request in "handling" status
- Display both "Cancel request" and "Cancel and stop its turn" buttons
- Include the request text and status

**Caption:**
"Full control over agent collaboration. Cancel requests, stop their work, or let them continue."

---

## Screenshot 8: Conversation List

**What to show:** Chat list with multiple active conversations

**Setup:**
- 5-6 conversations with descriptive names
- Mix of recent activity timestamps
- Show different agent types (Codex, Claude Code)
- Some with unread indicators or status badges

**Sample conversations:**
- "API integration" (2m ago, Claude Code)
- "Database migration" (1h ago, Codex)
- "UI redesign" (Yesterday, Claude Code)
- "Bug investigation" (2d ago)

**Caption:**
"Manage multiple tasks across conversations. Each keeps its own history, files, and context."

---

## Recording Tips

1. **Take screenshots in light mode** (default, better visibility)
2. **Use actual content, not Lorem ipsum**
3. **Keep text readable** but not too dense
4. **Show real AI responses** when possible
5. **Frame vertically** - portrait orientation only
6. **Capture at full resolution** (1290 × 2796 for iPhone 14 Pro Max)
7. **No notifications or popups** during capture
8. **Clean status bar** - full battery, good signal

## How to Capture

**Method 1: iPhone screenshot**
- Set up the screen exactly as described
- Press Volume Up + Side Button simultaneously
- Find in Photos app → Screenshots album

**Method 2: Simulator (if needed for perfection)**
- Open Xcode simulator with iPhone 14 Pro Max
- Run the app with test data
- Cmd+S to save screenshot
- Scales to correct size automatically

## After Capturing

1. Review each screenshot for:
   - No personal information visible
   - Clear, professional appearance
   - Text is readable
   - Proper framing (no cut-off elements)

2. Export at full resolution
3. Name files: `01-hero-chat.png`, `02-live-desktop.png`, etc.
4. Store in `Marketing/Screenshots/` folder

## App Store Upload

- Upload to App Store Connect → My Apps → [Mob] → App Store → Screenshots
- Choose iPhone 6.7" display size
- Upload in the order listed above
- First screenshot is the "hero" - most important!
