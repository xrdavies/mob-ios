import SwiftUI

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @State private var inputText = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let session = viewModel.currentSession {
                    // Timeline
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(session.messages) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }
                            }
                            .padding()
                        }
                        .onChange(of: session.messages.count) { _ in
                            if let last = session.messages.last {
                                withAnimation {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        Text("No conversation yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Ask the agent to do something")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                // Composer
                HStack(spacing: 8) {
                    TextField("Ask mob to do something…", text: $inputText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .disabled(!appState.isConnected)
                    
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .blue)
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !appState.isConnected)
                }
                .padding()
                .background(Color(uiColor: .systemBackground))
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        appState.showDesktopDrawer.toggle()
                    } label: {
                        Image(systemName: appState.showDesktopDrawer ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(appState.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(appState.isConnected ? "Connected" : "Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            viewModel.apiClient = appState.apiClient
            viewModel.loadSessions()
        }
        .sheet(item: $viewModel.activeQuestion) { question in
            QuestionSheet(question: question, viewModel: viewModel)
        }
    }
    
    private func send() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        
        inputText = ""
        viewModel.submit(prompt: prompt)
    }
}

struct MessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack {
            if message.role == "assistant" {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.content)
                        .padding(10)
                        .background(Color(uiColor: .systemGray5))
                        .cornerRadius(12)
                    
                    Text(formatTime(message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.content)
                        .padding(10)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                    
                    Text(formatTime(message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private func formatTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return "" }
        
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        return timeFormatter.string(from: date)
    }
}
