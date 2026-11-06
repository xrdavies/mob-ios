# App Store Preview Videos Guide

App Preview videos are optional but highly recommended. They autoplay (silent) when users browse the App Store.

## Requirements

- **Duration:** 15-30 seconds each (App Store limit: 30s)
- **Format:** MP4 or MOV, H.264 codec
- **Resolution:** 1080 × 1920 (portrait) or higher
- **Device:** iPhone 14 Pro Max or 15 Pro Max (6.7" display)
- **Orientation:** Portrait only
- **Sound:** Optional (videos autoplay muted, user can unmute)
- **Limit:** Up to 3 videos per device size

## Video 1: "Mob Your Work" (Overview)
**Duration:** ~25 seconds  
**Goal:** Show the core workflow - send task, agent works, view desktop

### Script

**0:00-0:03** - Open app, show conversation list  
*Action:* Tap to open a conversation titled "Build API endpoint"

**0:03-0:08** - Type and send a message  
*Action:* Type: "Add user authentication with JWT tokens"  
*Visual:* Show keyboard, then send button press  
*Smooth transition to next*

**0:08-0:13** - Agent responds  
*Visual:* Claude Code's avatar appears, streaming response with tool use  
*Show:* "Reading existing code..." then code being generated  
*Keep it brief - just enough to show AI is working*

**0:13-0:20** - Switch to live desktop view  
*Action:* Tap the desktop view icon  
*Visual:* Office Mac desktop appears, showing code editor with the actual work  
*Zoom slightly to show real-time updates*

**0:20-0:25** - Return to chat, show completion  
*Action:* Swipe back to chat  
*Visual:* Agent's completed response with "Done" indicator  
*End frame:* Clean chat view with completed task

**Text Overlays (optional):**
- "Send tasks from anywhere" (0:03)
- "AI agents work on your office computer" (0:10)
- "See live updates" (0:15)
- "Get results" (0:22)

---

## Video 2: "Collaborate" (Agent-to-Agent)
**Duration:** ~20 seconds  
**Goal:** Show @mention delegation between agents

### Script

**0:00-0:05** - Compose message with @mention  
*Action:* In a conversation, type: "@api please implement the user service"  
*Visual:* Show the @ picker appearing, selecting @api  
*Highlight:* The @api chip in the composed message

**0:05-0:10** - Send and show request indicator  
*Action:* Send the message  
*Visual:* Collaboration chip appears: "Request sent to @api"  
*Transition:* Smooth fade to Collaboration tab

**0:10-0:15** - View collaboration tab  
*Visual:* Show the request with status "handling"  
*Action:* Tap the request to open details  
*Show:* Request details sheet with status and controls

**0:15-0:20** - Agent replies  
*Visual:* Status changes to "replied"  
*Show:* Agent's response appears in timeline with code/result  
*End frame:* Clean success state showing completed collaboration

**Text Overlays:**
- "Mention agents with @" (0:02)
- "Delegate work instantly" (0:07)
- "Track every request" (0:12)
- "Get their results" (0:17)

---

## Video 3: "Access Everything" (Multi-feature)
**Duration:** ~28 seconds  
**Goal:** Show switching machines, desktop, files, USB

### Script

**0:00-0:05** - Switch machines  
*Action:* Settings → Machines, show 2-3 machines  
*Visual:* Tap to switch from "Office Mac" to "Lab Linux"  
*Highlight:* Smooth transition, connection indicator

**0:05-0:12** - Live desktop on Linux  
*Visual:* Desktop view showing Linux desktop (different from Mac)  
*Show:* Browser or IDE open, demonstrating it's a different machine  
*Quick pan/zoom to show detail*

**0:12-0:18** - File transfer  
*Action:* Switch to Files tab  
*Visual:* Upload a file (drag or picker), show progress bar  
*Show:* File uploading with percentage, then completing  
*Include download too if time permits*

**0:18-0:24** - USB device sharing  
*Action:* Open USB from settings or chat  
*Visual:* USB device list with "Arduino Uno" or similar  
*Action:* Tap to share device  
*Show:* Connection/sharing state

**0:24-0:28** - Return to chat  
*Visual:* Back to conversation, agent working with the shared device  
*End frame:* Clean state showing all capabilities working together

**Text Overlays:**
- "Multiple office computers" (0:02)
- "Stream any desktop" (0:08)
- "Transfer files instantly" (0:14)
- "Share USB devices" (0:20)
- "Work from anywhere" (0:26)

---

## Recording Setup

### Before Recording

1. **iPhone preparation:**
   - Fully charged or connected to power
   - Do Not Disturb enabled (no notifications)
   - Airplane mode or Wi-Fi only (hide cellular icons)
   - Set time to 9:41 AM
   - Close all background apps
   - Clean home screen if shown

2. **App preparation:**
   - Prepare all test data (conversations, files, machines)
   - Clear any personal/sensitive information
   - Have office Mac ready with clean desktop
   - Test the flow multiple times before recording
   - Practice smooth gestures (tapping, swiping)

3. **Office Mac preparation:**
   - Clean desktop background
   - Professional-looking project open in editor
   - No sensitive files or information visible
   - Good lighting if showing webcam
   - Hide personal info from dock/menu bar

### Recording Methods

**Method 1: Built-in Screen Recording (Easiest)**
1. Settings → Control Center → Add Screen Recording
2. Open Control Center, long-press Screen Recording
3. Turn off Microphone (unless adding voiceover)
4. Tap Start Recording
5. Perform the actions from script
6. Stop from Control Center or status bar

**Method 2: QuickTime on Mac (Better quality)**
1. Connect iPhone to Mac via USB
2. Open QuickTime Player → File → New Movie Recording
3. Click dropdown next to record → Select iPhone
4. Click Record
5. Perform actions on iPhone
6. Stop recording, save as MOV

**Method 3: Xcode Simulator (For perfect control)**
1. Run app in iPhone 14 Pro Max simulator
2. Prepare test data in app
3. Record screen with QuickTime or screenshot tool
4. Edit out any Xcode UI in post

### Recording Tips

1. **Smooth, deliberate gestures:**
   - Tap precisely on targets
   - Swipe smoothly and at consistent speed
   - Pause briefly between major actions
   - No hesitation or fumbling

2. **Timing:**
   - Don't rush - users need to understand what's happening
   - But keep it snappy - no dead time
   - Pause 0.5-1s after each major action
   - Time the total carefully (max 30s)

3. **Visual clarity:**
   - Hold phone steady (use tripod if available)
   - Keep fingers out of the way when possible
   - Good lighting - screen should be clearly visible
   - No glare or reflections

4. **Content:**
   - Use real, professional content
   - Keep text concise and readable
   - Show actual AI responses (not placeholders)
   - Demonstrate real functionality

5. **Multiple takes:**
   - Record each video 3-5 times
   - Pick the smoothest, clearest version
   - Small imperfections are OK (shows it's real)
   - But avoid obvious mistakes or hesitation

---

## Post-Production

### Required Edits

1. **Trim to length:**
   - Cut to exactly 15-30 seconds
   - Remove any dead time at start/end
   - Smooth transitions between sections

2. **Add overlays (optional but recommended):**
   - Product name "Mob" at start (1-2s)
   - Feature callouts as text overlays
   - Keep text large, clear, readable
   - Use simple, professional font
   - Match iOS/Apple aesthetic

3. **Optional enhancements:**
   - Subtle zoom-ins for emphasis
   - Smooth transitions between sections
   - Background music (if adding audio)
   - Sound effects for taps/actions

### Tools

**Free:**
- iMovie (Mac/iPhone) - simple editing
- DaVinci Resolve - professional, free
- Keynote - for text overlays

**Paid:**
- Final Cut Pro - professional Mac editor
- Adobe Premiere Pro - industry standard

### Export Settings

- **Format:** MP4 (H.264) or MOV
- **Resolution:** 1080 × 1920 (portrait) minimum
- **Frame rate:** 30 fps or 60 fps
- **Bitrate:** High quality (10-20 Mbps)
- **Audio:** 256 kbps AAC (if including sound)

---

## Text Overlay Best Practices

**Style:**
- Large, bold, sans-serif font (SF Pro or Helvetica)
- White text with subtle drop shadow for visibility
- Position: Lower third or upper third (avoid center)
- Duration: 2-3 seconds each
- Fade in/out smoothly (0.3s transition)

**Content:**
- Short phrases (3-5 words max)
- Focus on benefits, not features
- Active voice: "Send tasks" not "Tasks can be sent"
- Match the action on screen

**Examples:**
- Good: "Work from anywhere"
- Bad: "The app allows you to work remotely from any location"

---

## Apple Review Requirements

Videos must:
- Show actual app functionality (no mockups)
- Not include Apple device frames (just the screen content)
- Not reference other apps or platforms
- Not include pricing information
- Not include adult content or offensive material
- Match the app's actual capabilities

---

## File Organization

Save recordings as:
- `Marketing/Videos/01-overview-raw.mov` (original)
- `Marketing/Videos/01-overview-final.mp4` (edited, ready to upload)
- `Marketing/Videos/02-collaborate-raw.mov`
- `Marketing/Videos/02-collaborate-final.mp4`
- `Marketing/Videos/03-access-raw.mov`
- `Marketing/Videos/03-access-final.mp4`

Keep both raw and final versions for future edits.

---

## App Store Upload

1. Go to App Store Connect → My Apps → Mob
2. Select version → App Previews and Screenshots
3. Choose iPhone 6.7" display
4. Upload videos (they'll process, may take a few minutes)
5. Set poster frame (the thumbnail shown before autoplay)
6. Choose the most compelling moment, usually 2-3s in
7. Reorder videos if needed (first video is most important)

---

## Tips for Success

1. **Keep it real:** Show actual functionality, not staged perfection
2. **Tell a story:** Each video should have a clear beginning, middle, end
3. **Show value:** Focus on what users can do, not how the app works
4. **Be concise:** Every second counts in 15-30s
5. **Test on device:** View on actual iPhone before uploading
6. **Get feedback:** Show to colleagues/friends before submitting

---

## Alternative: Hire a Professional

If this feels overwhelming, consider:
- Freelancer on Fiverr/Upwork ($50-200 per video)
- App Store preview video specialists ($200-500 for 3 videos)
- Provide them with this guide + app access

But doing it yourself gives you full control and saves money!
