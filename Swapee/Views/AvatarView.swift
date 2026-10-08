import PhotosUI
import SwiftUI

/// A round profile photo, or the person's initials like Contacts and Messages.
struct AvatarView: View {
    let name: String
    let path: String?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let path {
                RemotePhoto(path: path, bucket: .avatars, contentMode: .fill)
            } else {
                Circle()
                    .fill(LinearGradient(colors: [Color(.systemGray2), Color(.systemGray3)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Text(Self.initials(name))
                            .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    /// "Alice Lee" → "AL", "小明" → "小".
    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        guard let first = words.first?.first else { return "" }
        if first.isLetter, first.isASCII {
            return words.compactMap(\.first).map { String($0).uppercased() }.joined()
        }
        return String(first)
    }
}

/// Your avatar with a menu to take, choose or remove a photo.
struct EditableAvatar: View {
    var size: CGFloat = 88

    @Environment(APIClient.self) private var api
    @Environment(PhotoLoader.self) private var photos
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var isSaving = false
    @State private var error: Error?

    var body: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button("Take Photo", systemImage: "camera") { showCamera = true }
            }
            Button("Choose Photo", systemImage: "photo.on.rectangle") { showPicker = true }
            if api.profile?.avatarPath != nil {
                Button("Remove Photo", systemImage: "trash", role: .destructive) { Task { await remove() } }
            }
        } label: {
            VStack(spacing: 8) {
                AvatarView(name: api.profile?.displayName ?? "", path: api.profile?.avatarPath, size: size)
                    .overlay {
                        if isSaving {
                            Circle().fill(.black.opacity(0.4))
                            ProgressView()
                        }
                    }
                Text(api.profile?.avatarPath == nil ? "Add Photo" : "Edit Photo")
                    .font(.subheadline)
            }
        }
        .disabled(isSaving)
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in Task { await save(data) } }
                .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await save(data)
                } else {
                    error = PhotoError.unreadable
                }
                pickerItem = nil
            }
        }
        .errorAlert("Couldn’t Update Photo", error: $error)
    }

    private func save(_ data: Data) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let jpeg = try await Task.detached(priority: .userInitiated) { try ImageProcessing.avatar(data) }.value
            try await api.setAvatar(jpeg: jpeg)
            if let path = api.profile?.avatarPath, let image = UIImage(data: jpeg) {
                photos.store(image, for: path, in: .avatars)
            }
        } catch is ImageProcessing.Failure {
            error = PhotoError.unreadable
        } catch {
            self.error = error
        }
    }

    private func remove() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await api.removeAvatar()
        } catch {
            self.error = error
        }
    }
}

/// Picking a photo before the account exists (first sign-in); it's uploaded when setup finishes.
struct AvatarDraftPicker: View {
    let name: String
    @Binding var jpeg: Data?

    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var error: Error?

    var body: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button("Take Photo", systemImage: "camera") { showCamera = true }
            }
            Button("Choose Photo", systemImage: "photo.on.rectangle") { showPicker = true }
            if jpeg != nil {
                Button("Remove Photo", systemImage: "trash", role: .destructive) { jpeg = nil }
            }
        } label: {
            VStack(spacing: 8) {
                Group {
                    if let jpeg, let image = UIImage(data: jpeg) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        AvatarView(name: name, path: nil, size: 88)
                    }
                }
                .frame(width: 88, height: 88)
                .clipShape(.circle)
                Text(jpeg == nil ? "Add Photo" : "Edit Photo")
                    .font(.subheadline)
            }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in prepare(data) }
                .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { prepare(data) }
                pickerItem = nil
            }
        }
        .errorAlert("Couldn’t Use Photo", error: $error)
    }

    private func prepare(_ data: Data) {
        Task {
            do {
                jpeg = try await Task.detached(priority: .userInitiated) { try ImageProcessing.avatar(data) }.value
            } catch {
                self.error = PhotoError.unreadable
            }
        }
    }
}
