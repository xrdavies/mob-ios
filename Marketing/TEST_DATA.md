# Test Data for App Store Marketing

This document provides realistic conversation content, file names, and settings to populate the app for screenshots and videos.

## Conversations (Chat List)

Create these conversations in the app for Screenshot 8 and general demos:

1. **"Build user dashboard"** (Claude Code, 2m ago)
   - Status: Active, agent just replied
   - Preview: "I'll create a dashboard component with..."

2. **"API integration"** (Claude Code, 15m ago)
   - Status: Completed
   - Preview: "Added the /users endpoint with JWT auth"

3. **"Database migration"** (Codex, 1h ago)
   - Status: Active, running
   - Preview: "Analyzing the schema changes..."

4. **"Fix login redirect"** (Claude Code, Yesterday)
   - Status: Completed
   - Preview: "Updated the auth flow to handle..."

5. **"Deploy to staging"** (Codex, 2d ago)
   - Status: Failed (shows retry capability)
   - Preview: "Error: Missing environment variable..."

6. **"UI redesign feedback"** (Claude Code, 3d ago)
   - Status: Completed
   - Preview: "I've updated the components based on..."

---

## Sample Chat Content

### For Screenshot 1: "Build user dashboard"

**Message 1 (You):**
```
Add a user dashboard page with an activity chart showing the last 30 days, and a list of recent items. Use shadcn/ui components and match the existing design system.
```

**Message 2 (Claude Code - Tool use):**
```
I'll create a user dashboard with an activity chart and recent items list. Let me start by checking the existing layout structure.

[Tool: Read src/app/layout.tsx]
```

**Message 3 (Claude Code - Streaming/Complete):**
```
I've created the dashboard page. Here's what I added:

1. **Dashboard Component** (`src/app/dashboard/page.tsx`):
   - Activity chart using Recharts with 30-day data
   - Recent items list with type indicators
   - Responsive grid layout
   - Loading states and empty states

2. **Data Hook** (`src/hooks/useDashboardData.ts`):
   - Fetches user activity from `/api/activity`
   - Caches with SWR for performance
   - Handles error states

The dashboard follows your design system using shadcn/ui Card, Button, and typography components. The chart updates automatically when new activity is logged.

[Shows generated code - actual TypeScript/React code visible]
```

---

### For Screenshot 3: Collaboration

**Message 1 (You):**
```
@api implement the user authentication endpoints - login, register, and token refresh. Use JWT with HTTP-only cookies.
```

**Message 2 (System/Collaboration):**
```
[Collaboration chip: "Request sent to @api"]
```

**Message 3 (@api):**
```
I'll implement the authentication endpoints. Let me check the existing API structure.

[Shows tool use and implementation work]

Done. I've added:
- POST /api/auth/login
- POST /api/auth/register  
- POST /api/auth/refresh

All use JWT tokens stored in HTTP-only cookies with CSRF protection. Tests included.
```

---

## Files for Screenshot 4

Create these in the Files tab:

**Uploading:**
- `design-mockup.png` (2.4 MB, 45% complete)
- `user-profile-icon.svg` (128 KB, queued)

**Downloaded:**
- `database-backup.sql` (15.3 MB, ✓ Complete)
- `build-output.zip` (8.7 MB, ✓ Complete)
- `api-docs.pdf` (1.2 MB, ✓ Complete)

**Failed (optional, to show retry):**
- `large-video.mp4` (125 MB, failed - connection lost)

---

## Machines for Screenshot 6

Configure these in Settings → Machines:

1. **Office Mac Studio** 
   - Status: Online (green indicator)
   - IP: 192.168.1.100
   - Mark as active/current

2. **Lab Linux Workstation**
   - Status: Offline (gray indicator)
   - IP: 10.0.50.25

3. **Home iMac**
   - Status: Online (green indicator)
   - IP: 192.168.1.150

---

## USB Devices for Screenshot 5

If showing USB feature, have these available:

- **Arduino Uno** (ATmega328P - /dev/ttyUSB0)
- **STM32 Dev Board** (STM32F4 - /dev/ttyACM0)
- **USB Serial Adapter** (FTDI FT232 - /dev/ttyUSB1)

Or alternatively:
- **Raspberry Pi Pico** (RP2040)
- **ESP32 DevKit**
- **Debug Probe** (CMSIS-DAP)

---

## Collaboration Requests

For the Collaboration tab (Screenshot 7):

**Active Request:**
- From: Main conversation
- To: @api
- Text: "Implement user service with CRUD operations"
- Status: handling
- Created: 5 minutes ago

**Completed Request:**
- From: Main conversation  
- To: @backend
- Text: "Add database migration for new schema"
- Status: replied
- Completed: 1 hour ago

**Clarification Request (optional):**
- From: @api
- To: You
- Text: "Should the user service include email verification?"
- Status: needs_clarification
- Created: 10 minutes ago

---

## Agent Names and Handles

Use these agent handles consistently:

- `@api` - API implementation specialist
- `@backend` - Backend services and databases
- `@frontend` - UI and React components
- `@devops` - Deployment and infrastructure

---

## Office Desktop Content

For live desktop screenshots/videos, prepare:

**Mac Desktop:**
- VS Code open with a real project
- File: `src/components/Dashboard.tsx` or similar
- Terminal showing: `npm run dev` or build output
- Clean desktop background (solid color or subtle pattern)
- Dock: VS Code, Terminal, Chrome, Xcode
- No personal files or sensitive information visible

**Linux Desktop:**
- VS Code or other editor
- Different wallpaper than Mac (to show it's different)
- Terminal with command prompt
- Maybe a browser window

---

## Text for Composer (Typing Demos)

Short, clear messages to type in videos:

1. "Add user authentication with JWT tokens"
2. "@api please implement the user service"
3. "Fix the login redirect issue"
4. "Deploy the latest changes to staging"
5. "Update the dashboard component styling"

---

## Settings Content

**User profile (if visible):**
- Name: Leave empty or use "Demo User"
- No personal information

**Machine settings:**
- Quality: Medium (or show switching between Low/Medium/High)
- Audio: Enabled
- Keyboard: Follow System

---

## App State for Recording

**Before recording each screenshot/video:**

1. Clear any error states or alerts
2. Ensure good "signal" indicators (Wi-Fi, connection)
3. Set time to 9:41 AM
4. Full battery or hide battery percentage
5. Enable Do Not Disturb
6. Close any modal dialogs or sheets
7. Return to default tab/view unless showing a specific feature

---

## Realistic Timing

Make timestamps feel natural:

- "2m ago" - just happened
- "15m ago" - recent
- "1h ago" - within the hour
- "Yesterday" - previous day
- "2d ago" - two days back
- "3d ago" - older but still relevant

Don't use exact times like "2:34 PM" unless showing a specific event.

---

## Pro Tips

1. **Consistency:** Use the same agent names across all screenshots
2. **Realism:** Actual code snippets, real file extensions, plausible sizes
3. **Clean:** No typos, proper capitalization, complete sentences
4. **Professional:** Technical but accessible language
5. **Variety:** Mix completed, active, and failed states
6. **Context:** Each conversation should tell a mini-story

---

## Quick Test Data Setup Checklist

Before recording, verify:

- [ ] 5-6 conversations in chat list with varied status/timing
- [ ] Main conversation has realistic message history
- [ ] Files tab has mix of complete/in-progress/queued
- [ ] Collaboration tab has at least 2 requests
- [ ] Settings shows 2-3 machines
- [ ] USB devices available (if showing that feature)
- [ ] Office Mac desktop is clean and professional
- [ ] No notifications or popups enabled
- [ ] Time set to 9:41 AM
- [ ] Good connection indicators

---

## Optional: App Store Description Text

While we're preparing marketing materials, here's suggested App Store description text:

**Subtitle (30 characters max):**
"AI agents on your computer"

**Description:**

Mob lets you work with AI agents that run on your office computer, controlled from your phone or laptop.

**Chat with AI Agents**
Send tasks and watch your agents work in real-time. Claude Code, Codex, and Pi run on your office machine with full access to your codebase, tools, and environment.

**Live Desktop**
See your office computer's screen in real-time. Stream video with audio, control quality based on your connection.

**Agent Collaboration**
Delegate work between agents with @mentions. "Hey @api, implement this endpoint" - your agents work together while you coordinate.

**Files & USB**
Transfer files with pause/resume and verification. Share USB devices like debug probes, microcontrollers, and serial adapters to remote computers.

**Multiple Machines**
Connect your office Mac, Linux workstation, and home computer. Switch between them instantly, each with its own conversations and settings.

**Privacy First**
Direct connection to your machines. No code sent to external servers. Your agents work on your hardware with your credentials.

Perfect for developers who want AI help without switching machines, remote workers who need access to office hardware, and teams doing mob programming with AI.

---

**Keywords (100 characters, comma-separated):**
AI,developer,remote,desktop,coding,programming,assistant,collaboration,USB,workspace

---

**Promotional Text (170 characters, optional):**
Control AI agents running on your office computer from anywhere. Real-time desktop streaming, agent collaboration, and USB device sharing for developers.
