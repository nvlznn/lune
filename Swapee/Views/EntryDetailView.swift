import SwiftUI

/// One of your own pages: the photo, the text, and who has seen it. The text can be edited at night.
struct EntryDetailView: View {
    let canEdit: Bool

    @Environment(APIClient.self) private var api
    @State private var entry: Entry
    @State private var editing = false

    init(entry: Entry, canEdit: Bool) {
        self.canEdit = canEdit
        _entry = State(initialValue: entry)
    }

    var body: some View {
        List {
            Section {
                RemotePhoto(path: entry.storagePath)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 10))
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .accessibilityLabel("Your photo")
                Text(entry.text)
                    .textSelection(.enabled)
            } footer: {
                Text(footer)
            }

            if let seenBy = entry.seenBy {
                Section {
                    if seenBy.isEmpty {
                        Text("No one has seen it yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(seenBy) { viewer in
                        LabeledContent {
                            Text(PhotoTime.standalone(viewer.seenAt))
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: viewer.name, path: viewer.avatarPath, size: 32)
                                Text(viewer.name)
                            }
                        }
                    }
                } header: {
                    Text("Seen By")
                } footer: {
                    Text("Friends see your page after writing theirs, tonight and tomorrow night.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(LuneDay.title(entry.day))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
            }
        }
        .sheet(isPresented: $editing) {
            EditTextSheet(entry: entry) { entry = $0 }
        }
    }

    private var footer: String {
        let time = PhotoTime.caption(takenAt: entry.takenAt, uploadedAt: entry.createdAt)
        return entry.editedAt == nil ? time : "\(time) · Edited"
    }
}

/// Editing a page's text, like a note in Reminders.
private struct EditTextSheet: View {
    let entry: Entry
    let onSaved: (Entry) -> Void

    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    @State private var error: Error?

    init(entry: Entry, onSaved: @escaping (Entry) -> Void) {
        self.entry = entry
        self.onSaved = onSaved
        _text = State(initialValue: entry.text)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("How was the day?", text: $text, axis: .vertical)
                        .lineLimit(4...16)
                        .onChange(of: text) { _, newValue in
                            if newValue.count > 500 { text = String(newValue.prefix(500)) }
                        }
                } footer: {
                    Text("\(text.count) / 500").monospacedDigit()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Done") { Task { await save() } }
                            .disabled(trimmed.isEmpty || trimmed == entry.text)
                    }
                }
            }
            .errorAlert("Couldn’t Save", error: $error)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            var updated = try await api.editEntryText(entry.entryId, text: trimmed)
            updated.seenBy = updated.seenBy ?? entry.seenBy
            onSaved(updated)
            NotificationCenter.default.post(name: .luneDidChange, object: nil)
            dismiss()
        } catch {
            self.error = error
        }
    }
}
