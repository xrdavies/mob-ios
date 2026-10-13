import SwiftUI

struct QuestionSheet: View {
    let question: Question
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var textAnswer = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.text)
                        .font(.headline)
                    
                    if let details = question.details, !details.isEmpty {
                        Text(details)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .systemGray6))
                .cornerRadius(12)
                
                if question.kind == "approval" {
                    // Approve / Deny buttons
                    VStack(spacing: 12) {
                        Button {
                            viewModel.answerQuestion(question, approved: true)
                            dismiss()
                        } label: {
                            Text("Approve")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.green)
                                .foregroundStyle(.white)
                                .cornerRadius(10)
                        }
                        
                        Button {
                            viewModel.answerQuestion(question, approved: false)
                            dismiss()
                        } label: {
                            Text("Deny")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red)
                                .foregroundStyle(.white)
                                .cornerRadius(10)
                        }
                    }
                } else if let options = question.options, !options.isEmpty {
                    // Option buttons
                    VStack(spacing: 12) {
                        ForEach(options, id: \.self) { option in
                            Button {
                                viewModel.answerQuestion(question, answer: option)
                                dismiss()
                            } label: {
                                Text(option)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .foregroundStyle(.white)
                                    .cornerRadius(10)
                            }
                        }
                    }
                } else if question.allowText {
                    // Text input
                    TextField("Your answer", text: $textAnswer, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                    
                    Button {
                        viewModel.answerQuestion(question, answer: textAnswer)
                        dismiss()
                    } label: {
                        Text("Send")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(textAnswer.isEmpty ? Color.gray : Color.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(10)
                    }
                    .disabled(textAnswer.isEmpty)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle(question.kind == "approval" ? "Approval" : "Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
