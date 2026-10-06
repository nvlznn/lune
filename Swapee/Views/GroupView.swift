import PhotosUI
import SwiftUI

/// One group: today's upload area on top, received photos below.
struct GroupView: View {
    let groupID: UUID

    @Environment(APIClient.self) private var api
    @Environment(AppRouter.self) private var router
    @Environment(PhotoLoader.self) private var photos
    @Environment(\.scenePhase) private var scenePhase

    @State private var summary: GroupSummary?
    @State private var state: GroupState?
    @State private var error: Error?

    @State private var pickerItem: PhotosPickerItem?
    @State private var draft: ProcessedPhoto?
    @State private var draftImage: UIImage?
    @State private var caption = ""
    @FocusState private var captionFocused: Bool
    @State private var showCamera = false
    @State private var isProcessing = false
    @State private var isSending = false
    @State private var confirmSend = false
    @State private var sentCount = 0

    @State private var showMembers = false
    @State private var confirmLeave = false

    init(groupID: UUID, summary: GroupSummary?) {
        self.groupID = groupID
        _summary = State(initialValue: summary)
    }

    var body: some View {
        List {
            Section {
                todayContent
            } header: {
                Text("Today")
            } footer: {
                if state?.uploadedToday == false {
                    Text("Each photo you send lets you receive one from a friend. Sent photos can’t be changed or deleted.")
                }
            }

            if let summary, summary.memberCount == 1 {
                Section {
                    InviteCodeRow(group: summary)
                } header: {
                    Text("Invite Friends")
                } footer: {
                    Text("Once a friend joins with the invite code, you can start swapping photos.")
                }
            }

            receivedSection
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(summary?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if captionFocused {
                    Button("Done") { captionFocused = false }
                        .fontWeight(.semibold)
                } else {
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Members & Invite Code", systemImage: "person.2") { showMembers = true }
                        Button("Leave Group", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            confirmLeave = true
                        }
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showMembers) {
            if let summary {
                MembersView(group: summary) { router.path.removeAll() }
            }
        }
        .refreshable { await refresh() }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .swapeePhotoAvailable)) { _ in
            Task { await refresh() }
        }
        .onChange(of: pickerItem) { _, item in
            if let item { Task { await prepare(item) } }
        }
        .onDisappear { SeenPhotos.markSeen(groupID) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in Task { await prepare(data) } }
                .ignoresSafeArea()
        }
        .alert("Send This Photo?", isPresented: $confirmSend) {
            Button("Send") { Task { await send() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can’t change or delete it, and you can’t send another photo to this group today.")
        }
        .alert("Leave “\(summary?.name ?? "")”?", isPresented: $confirmLeave) {
            Button("Leave Group", role: .destructive) { Task { await leave() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos you sent to this group will be deleted.")
        }
        .errorAlert("Something Went Wrong", error: $error)
        .sensoryFeedback(.success, trigger: sentCount)
    }

    // MARK: - Today

    @ViewBuilder
    private var todayContent: some View {
        if let state, state.uploadedToday, let photo = state.todayPhoto {
            NavigationLink {
                OwnPhotoView(groupID: groupID, photo: photo)
            } label: {
                HStack(spacing: 12) {
                    RemotePhoto(path: photo.storagePath, contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sent Today")
                        Text(photo.seenSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if let draftImage {
            Image(uiImage: draftImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 420)
                .clipShape(.rect(cornerRadius: 10))
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                .accessibilityLabel("Selected photo")
            // Like a note in Reminders: Return adds a line, Done (top right) dismisses the keyboard.
            TextField("Add a caption", text: $caption, axis: .vertical)
                .lineLimit(1...6)
                .focused($captionFocused)
                .disabled(isSending)
                .onChange(of: caption) { _, newValue in
                    if newValue.count > 140 { caption = String(newValue.prefix(140)) }
                }
            Button {
                captionFocused = false
                confirmSend = true
            } label: {
                HStack {
                    Text("Send")
                    Spacer()
                    if isSending { ProgressView() }
                }
            }
            .disabled(isSending)
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text("Choose Another")
            }
            .disabled(isSending)
            if CameraPicker.isAvailable {
                Button("Take Another") { showCamera = true }
                    .disabled(isSending)
            }
        } else if isProcessing || state == nil {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 24)
        } else {
            ContentUnavailableView {
                Label("No Photo Today", systemImage: "photo")
            } actions: {
                if CameraPicker.isAvailable {
                    Button("Take Photo") { showCamera = true }
                        .buttonStyle(.borderedProminent)
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text("Choose Photo")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Received

    @ViewBuilder
    private var receivedSection: some View {
        if let state, state.isWaiting || !state.received.isEmpty {
            Section("Received") {
                if state.isWaiting {
                    ContentUnavailableView {
                        Label("Waiting for a Photo", systemImage: "clock")
                    } description: {
                        Text("You’ll get one when a friend sends a photo.")
                    }
                }
                ForEach(state.received) { photo in
                    ReceivedPhotoRow(photo: photo) {
                        Task { await refresh() }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() async {
        do {
            if let latest = try await api.myGroups().first(where: { $0.id == groupID }) {
                summary = latest
            }
            var current = try await api.groupState(groupID)
            if current.credits > 0 {
                try await api.claimAll(groupID: groupID)
                current = try await api.groupState(groupID)
            }
            state = current
            SeenPhotos.markSeen(groupID)
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch APIError.server(code: "not_member") {
            router.path.removeAll()
        } catch {
            self.error = error
        }
    }

    private func prepare(_ item: PhotosPickerItem) async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ImageProcessing.Failure.unreadable
            }
            await prepare(data)
        } catch {
            self.error = PhotoError.unreadable
        }
    }

    /// From the library or the camera.
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
        guard let draft, !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = try await api.uploadPhoto(
                groupID: groupID, jpeg: draft.jpeg, takenAt: draft.takenAt, caption: trimmed.isEmpty ? nil : trimmed
            )
            if let draftImage { photos.store(draftImage, for: path) }
            self.draft = nil
            draftImage = nil
            caption = ""
            pickerItem = nil
            sentCount += 1
            await refresh()
            await PushRegistration.requestAfterFirstUpload()
        } catch {
            self.error = error
        }
    }

    private func leave() async {
        do {
            try await api.leaveGroup(groupID)
            router.path.removeAll()
        } catch {
            self.error = error
        }
    }
}

private enum PhotoError: LocalizedError {
    case unreadable
    var errorDescription: String? { "This photo couldn’t be read. Try another one." }
}

/// The invite code and a button that copies it.
struct InviteCodeRow: View {
    let group: GroupSummary

    @State private var copied = false

    var body: some View {
        LabeledContent("Invite Code") {
            Text(group.inviteCode)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
        Button {
            UIPasteboard.general.string = group.inviteCode
            copied = true
        } label: {
            if copied {
                Label("Copied", systemImage: "checkmark")
            } else {
                Label("Copy Invite Code", systemImage: "doc.on.doc")
            }
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
