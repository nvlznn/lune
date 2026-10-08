import PhotosUI
import SwiftUI

/// Writing a page: one photo and a few words. The photo is fixed once sent; the text can be edited later.
struct ComposeSheet: View {
    let day: String
    let isYesterday: Bool
    let onSent: () -> Void

    @Environment(APIClient.self) private var api
    @Environment(PhotoLoader.self) private var photos
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var draft: ProcessedPhoto?
    @State private var draftImage: UIImage?
    @State private var text = ""
    @State private var isProcessing = false
    @State private var isSending = false
    @State private var showCamera = false
    @State private var confirmSend = false
    @State private var error: Error?
    @FocusState private var textFocused: Bool

    private static let limit = 500
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { draft != nil && !trimmed.isEmpty && !isSending }

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
                    }
                    if CameraPicker.isAvailable {
                        Button(draft == nil ? "Take Photo" : "Retake Photo", systemImage: "camera") { showCamera = true }
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(draft == nil ? "Choose Photo" : "Choose Another", systemImage: "photo.on.rectangle")
                    }
                } footer: {
                    Text("One photo for the day. It can’t be changed after you send it.")
                }

                Section {
                    TextField(isYesterday ? "How was yesterday?" : "How was today?", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($textFocused)
                        .onChange(of: text) { _, newValue in
                            if newValue.count > Self.limit { text = String(newValue.prefix(Self.limit)) }
                        }
                } footer: {
                    Text("\(text.count) / \(Self.limit)")
                        .monospacedDigit()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(isSending)
            .navigationTitle(isYesterday ? "Yesterday’s Page" : "Tonight’s Page")
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
                    } else {
                        Button("Send") { confirmSend = true }
                            .disabled(!canSend)
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                if let item { Task { await prepare(item) } }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in Task { await prepare(data) } }
                    .ignoresSafeArea()
            }
            .alert("Send This Page?", isPresented: $confirmSend) {
                Button("Send") { Task { await send() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Friends who wrote too will see it. You can edit the text later, but not the photo.")
            }
            .errorAlert("Couldn’t Send", error: $error)
        }
        .interactiveDismissDisabled(draft != nil || !text.isEmpty)
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
        guard let draft, canSend else { return }
        isSending = true
        defer { isSending = false }
        do {
            let entry = try await api.writeEntry(day: day, jpeg: draft.jpeg, takenAt: draft.takenAt, text: trimmed)
            if let draftImage { photos.store(draftImage, for: entry.storagePath) }
            dismiss()
            onSent()
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
