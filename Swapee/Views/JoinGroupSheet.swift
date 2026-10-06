import SwiftUI

struct JoinGroupSheet: View {
    let onJoined: (GroupInfo) -> Void

    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isJoining = false
    @State private var notFound = false
    @State private var error: Error?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invite Code", text: $code)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .focused($focused)
                        .submitLabel(.join)
                        .onSubmit(join)
                        .onChange(of: code) { _, newValue in
                            let cleaned = InviteCode.clean(newValue)
                            if cleaned != newValue { code = cleaned }
                        }
                } footer: {
                    Text("Enter the 6-character code a friend shared with you.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Join Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isJoining {
                        ProgressView()
                    } else {
                        Button("Done", action: join).disabled(code.count != 6)
                    }
                }
            }
            .alert("Invite Code Not Found", isPresented: $notFound) {
                Button("OK") {}
            } message: {
                Text("Check the code and try again.")
            }
            .errorAlert("Couldn’t Join Group", error: $error)
            .onAppear { focused = true }
        }
    }

    private func join() {
        guard code.count == 6, !isJoining else { return }
        isJoining = true
        Task {
            defer { isJoining = false }
            do {
                if let group = try await api.joinGroup(code: code) {
                    dismiss()
                    onJoined(group)
                } else {
                    notFound = true
                }
            } catch {
                self.error = error
            }
        }
    }
}

enum InviteCode {
    /// Invite codes only use these characters (no 0/O or 1/I).
    static let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// What the field should hold after typing or pasting. A pasted invite message
    /// ("Join my group … with invite code PDT9TA") yields just the code.
    static func clean(_ input: String) -> String {
        if let code = find(in: input) { return code }
        return String(input.uppercased().filter(alphabet.contains).prefix(6))
    }

    /// A 6-character code inside longer text. Prefers words written in capitals, as codes are shared,
    /// then the last candidate, since the share message ends with the code.
    static func find(in text: String) -> String? {
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard words.count > 1 else { return nil }
        let candidates = words.filter { $0.count == 6 && $0.uppercased().allSatisfy(alphabet.contains) }
        return (candidates.last { $0 == $0.uppercased() } ?? candidates.last)?.uppercased()
    }
}
