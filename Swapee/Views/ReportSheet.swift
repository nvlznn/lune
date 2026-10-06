import SwiftUI

struct ReportSheet: View {
    let photo: ReceivedPhoto

    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var reason = Reason.inappropriate
    @State private var details = ""
    @State private var isSending = false
    @State private var sent = false
    @State private var error: Error?

    enum Reason: String, CaseIterable, Identifiable {
        case inappropriate = "Inappropriate or offensive"
        case harassment = "Harassment or bullying"
        case spam = "Spam"
        case other = "Other"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(Reason.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Reason")
                }

                Section {
                    TextField("Details (Optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text("Swapee reviews every report. The other person won’t know who reported them.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Report Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send", action: send)
                    }
                }
            }
            .alert("Report Sent", isPresented: $sent) {
                Button("OK") { dismiss() }
            } message: {
                Text("Thank you. To stop receiving photos from \(photo.senderName), you can block them.")
            }
            .errorAlert("Couldn’t Send Report", error: $error)
        }
    }

    private func send() {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let text = details.trimmingCharacters(in: .whitespacesAndNewlines)
                try await api.report(photoID: photo.photoId, reason: text.isEmpty ? reason.rawValue : "\(reason.rawValue): \(text)")
                sent = true
            } catch {
                self.error = error
            }
        }
    }
}
