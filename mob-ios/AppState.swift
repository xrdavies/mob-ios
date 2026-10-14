import SwiftUI
import Combine

/// Global app state: connection settings, active machine, notifications
class AppState: ObservableObject {
    @Published var mobdURL: String = UserDefaults.standard.string(forKey: "mobdURL") ?? "" {
        didSet {
            UserDefaults.standard.set(mobdURL, forKey: "mobdURL")
            updateAPIClient(baseURL: mobdURL)
        }
    }
    
    @Published var isConnected: Bool = false
    @Published var health: Health?
    @Published var showDesktopDrawer: Bool = false
    
    private(set) var apiClient: APIClient
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        let initialURL = UserDefaults.standard.string(forKey: "mobdURL") ?? ""
        self.apiClient = APIClient(baseURL: initialURL)
    }
    
    private func updateAPIClient(baseURL: String) {
        self.apiClient = APIClient(baseURL: baseURL)
    }
    
    func checkHealth() {
        guard !mobdURL.isEmpty else {
            isConnected = false
            health = nil
            return
        }

        Task {
            do {
                let h = try await apiClient.getHealth()
                await MainActor.run {
                    self.health = h
                    self.isConnected = h.ok
                }
            } catch {
                await MainActor.run {
                    self.isConnected = false
                    self.health = nil
                }
            }
        }
    }
}
