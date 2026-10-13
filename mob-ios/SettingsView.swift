import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Circle()
                            .fill(appState.isConnected ? Color.green : Color.red)
                            .frame(width: 12, height: 12)
                        Text(appState.isConnected ? "Connected" : "Not connected")
                            .foregroundStyle(appState.isConnected ? .green : .red)
                    }
                    
                    if let health = appState.health {
                        LabeledContent("Default runner", value: health.runner ?? "—")
                        if let runners = health.runners, !runners.isEmpty {
                            LabeledContent("Runners", value: "\(runners.count)")
                        }
                    }
                } header: {
                    Text("Status")
                }
                
                Section {
                    TextField("http://192.168.1.100:8080", text: $appState.mobdURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    
                    Button("Test Connection") {
                        appState.checkHealth()
                    }
                } header: {
                    Text("Office Mac")
                } footer: {
                    Text("Enter your office Mac's mobd URL (e.g. http://192.168.1.100:8080 or via Tailscale)")
                }
                
                Section {
                    Toggle("Local notifications", isOn: .constant(true))
                        .disabled(true)
                    
                    Toggle("Show desktop drawer", isOn: $appState.showDesktopDrawer)
                } header: {
                    Text("Preferences")
                }
                
                Section {
                    Link("GitHub: mob", destination: URL(string: "https://github.com/xrdavies/mob")!)
                    Link("GitHub: mob-ios", destination: URL(string: "https://github.com/xrdavies/mob-ios")!)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
