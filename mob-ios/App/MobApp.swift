import BackgroundTasks
import SwiftUI

/// Background refresh ID (also listed in Info.plist).
let refreshTaskId = "com.xrdavies.mob-ios.refresh"

@main
struct MobApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var phase

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { task in
            MobApp.handleRefresh(task as! BGAppRefreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task { appState.notifier.requestPermission() }
        }
        .onChange(of: phase) { _, now in
            appState.foreground = now == .active
            appState.files.foreground = now == .active
            if now == .active { appState.chat.resync() }
            if now == .background {
                appState.files.pauseAll()
                MobApp.scheduleRefresh()
                Task { await appState.rememberSessions() }
            }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// iOS wakes the app now and then; check the machines for questions and finished tasks.
    private static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task { @MainActor in
            await AppState.shared?.backgroundCheck()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ChatView(openSettings: { tab = 2 })
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .badge(app.waitingCount)
                .tag(0)
            TasksView(openChat: { id in
                app.chat.open(id)
                tab = 0
            })
            .tabItem { Label("Tasks", systemImage: "list.bullet") }
            .tag(1)
            FilesView()
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .onChange(of: app.showChat) { tab = 0 }
        .onChange(of: tab, initial: true) { app.chatTabVisible = tab == 0 }
    }
}
