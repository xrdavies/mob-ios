import SwiftUI
import Combine

/// Global app state: connection settings, active machine, notifications
class AppState: ObservableObject {
    @Published var mobdURL: String = UserDefaults.standard.string(forKey: "mobdURL") ?? "" {
        didSet {
            UserDefaults.standard.set(mobdURL, forKey: "mobdURL")
        }
    }
    
    @Published var isConnected: Bool = false
    @Published var health: Health?
    @Published var showDesktopDrawer: Bool = false
    
    let apiClient: APIClient
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.apiClient = APIClient(baseURL: mobdURL)
        
        // Update APIClient when URL changes
        $mobdURL
            .sink { [weak self] url in
                self?.apiClient.updateBaseURL(url)
                self?.checkHealth()
            }
            .store(in: &cancellables)
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
