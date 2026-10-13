import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    
    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                ChatView()
                    .tabItem {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                    .tag(0)
                
                TasksView()
                    .tabItem {
                        Label("Tasks", systemImage: "list.bullet")
                    }
                    .tag(1)
                
                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(2)
            }
            
            // Desktop drawer slides in from the right
            if appState.showDesktopDrawer {
                DesktopDrawer()
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut, value: appState.showDesktopDrawer)
        .onAppear {
            appState.checkHealth()
        }
    }
}
