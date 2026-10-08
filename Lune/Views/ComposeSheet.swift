import PhotosUI
import SwiftUI

/// Writing tonight's page (one photo and a few words) and choosing who gets it, or editing a page
/// you haven't sent. Sending is final.
struct ComposeSheet: View {
    enum Mode {
        case new(day: String)
        case edit(Entry)
    }

    let mode: Mode
    let onDone: (Entry) -> Void

    @Environment(APIClient.self) private var api
    @Environment(PhotoLoader.self) private var photos
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var draft: ProcessedPhoto?
    @State private var draftImage: UIImage?
    @State private var text: String
    @State private var friends: [Friend] = []
    @State private var groups: [FriendGroup] = []
    @State private var recipients: Set<UUID> = []
    @State private var friendsLoaded = false
    @State private var isProcessing = false
    @State private var isSending = false
    @State private var showCamera = false
    @State private var confirmSend = false
    @State private var error: Error?
    @FocusState private var textFocused: Bool

    init(mode: Mode, onDone: @escaping (Entry) -> Void) {
        self.mode = mode
        self.onDone = onDone
        if case .edit(let entry) = mode {
            _text = State(initialValue: entry.text)
        } else {
            _text = State(initialValue: "")
        }
    }

    private static let limit = 500
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var editing: Entry? {
        if case .edit(let entry) = mode { entry } else { nil }
    }

    private var canSend: Bool {
        guard !trimmed.isEmpty, !isSending else { return false }
        if let editing { return draft != nil || trimmed != editing.text }
        return draft != nil && friendsLoaded
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let draftImage {
                        Image(uiImage: draftImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 360)
                            .clipShape(.rect(cornerRadius: 10))
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                            .accessibilityLabel("Selected photo")
                    } else if isProcessing {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    } else if let editing {
                        RemotePhoto(path: editing.storagePath)
                            .frame(maxWidth: .infinity, maxHeight: 360)
                            .clipShape(.rect(cornerRadius: 10))
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                            .accessibilityLabel("Current photo")
                    }
                    let hasPhoto = draft != nil || editing != nil
                    if CameraPicker.isAvailable {
                        Button(hasPhoto ? "Retake Photo" : "Take Photo", systemImage: "camera") { showCamera = true }
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(hasPhoto ? "Choose Another" : "Choose Photo", systemImage: "photo.on.rectangle")
                    }
                } footer: {
                    if editing == nil {
                        Text("One photo for the day.")
                    }
                }

                Section {
                    TextField("How was today?", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($textFocused)
                        .onChange(of: text) { _, newValue in
                            if newValue.count > Self.limit { text = String(newValue.prefix(Self.limit)) }
                        }
                } footer: {
                    Text("\(text.count) / \(Self.limit)")
                        .monospacedDigit()
                }

                if editing == nil {
                    Section {
                        if friendsLoaded {
                            NavigationLink {
                                RecipientsPicker(friends: friends, groups: groups, selection: $recipients)
                                    .navigationTitle("Send To")
                                    .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                LabeledContent("Send To", value: Audience.summary(recipients, friends: friends, groups: groups))
                            }
                        } else {
                            LabeledContent("Send To") { ProgressView() }
                        }
                    } footer: {
                        Text(recipients.isEmpty
                            ? "Only you will see it. You can still edit it, delete it, or send it later today."
                            : "Once sent, a page can’t be edited or deleted.")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(isSending)
            .navigationTitle(editing == nil ? "Tonight’s Page" : "Edit Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Like Reminders: Done while typing, then Send once you've looked it over.
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else if textFocused {
                        Button("Done") { textFocused = false }
                    } else if editing != nil {
                        Button("Save") { Task { await send() } }
                            .disabled(!canSend)
                    } else {
                        Button(recipients.isEmpty ? "Save" : "Send") { confirmSend = true }
                            .disabled(!canSend)
                    }
                }
            }
            .task { if editing == nil { await loadFriends() } }
            .onChange(of: pickerItem) { _, item in
                if let item { Task { await prepare(item) } }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in Task { await prepare(data) } }
                    .ignoresSafeArea()
            }
            .alert(Audience.question(recipients, friends: friends, groups: groups), isPresented: $confirmSend) {
                Button(recipients.isEmpty ? "Save" : "Send") { Task { await send() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(recipients.isEmpty
                    ? "You can still edit it, delete it, or send it later today."
                    : "It arrives right away and can’t be edited or deleted.")
            }
            .errorAlert(editing == nil ? "Couldn’t Send" : "Couldn’t Save", error: $error)
        }
        .interactiveDismissDisabled(draft != nil || trimmed != (editing?.text ?? ""))
    }

    /// Friends and groups for choosing recipients. Every friend is chosen to start with.
    private func loadFriends() async {
        do {
            async let friends = api.friends()
            async let groups = api.groups()
            (self.friends, self.groups) = try await (friends, groups)
            recipients = Set(self.friends.map(\.userId))
            friendsLoaded = true
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }

    private func prepare(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ImageProcessing.Failure.unreadable
            }
            await prepare(data)
        } catch {
            self.error = PhotoError.unreadable
        }
    }

    /// From the library or the camera: read the capture time, downscale, strip metadata.
    private func prepare(_ data: Data) async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let processed = try await Task.detached(priority: .userInitiated) {
                try ImageProcessing.process(data)
            }.value
            draft = processed
            draftImage = UIImage(data: processed.jpeg)
        } catch {
            self.error = PhotoError.unreadable
        }
    }

    private func send() async {
        guard canSend else { return }
        isSending = true
        defer { isSending = false }
        do {
            let entry: Entry
            switch mode {
            case .new(let day):
                guard let draft else { return }
                entry = try await api.writeEntry(
                    day: day, jpeg: draft.jpeg, takenAt: draft.takenAt, text: trimmed, recipients: Array(recipients)
                )
            case .edit(let original):
                entry = try await api.updateEntry(original.entryId, text: trimmed, jpeg: draft?.jpeg, takenAt: draft?.takenAt)
            }
            if let draftImage { photos.store(draftImage, for: entry.storagePath) }
            dismiss()
            onDone(entry)
            NotificationCenter.default.post(name: .luneDidChange, object: nil)
        } catch {
            self.error = error
        }
    }
}

enum PhotoError: LocalizedError {
    case unreadable
    var errorDescription: String? { "This photo couldn’t be read. Try another one." }
}
