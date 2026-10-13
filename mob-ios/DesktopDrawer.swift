import SwiftUI

struct DesktopDrawer: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack(spacing: 0) {
            // Dim overlay
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.showDesktopDrawer = false
                }
            
            // Drawer
            VStack {
                HStack {
                    Text("Office Desktop")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button {
                        appState.showDesktopDrawer = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.gray)
                            .font(.title2)
                    }
                }
                .padding()
                
                // VNC view placeholder (TODO: implement WebSocket VNC client)
                ZStack {
                    Rectangle()
                        .fill(Color(uiColor: .systemGray5))
                    
                    VStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        
                        Text("Live desktop view")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        
                        Text("VNC over WebSocket\n(TODO: implement)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                
                Spacer()
            }
            .frame(width: UIScreen.main.bounds.width * 0.85)
            .background(Color(uiColor: .systemBackground))
            .shadow(radius: 10)
        }
    }
}
