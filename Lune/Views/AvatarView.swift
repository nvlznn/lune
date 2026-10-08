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

/// Your avatar with a menu to take, choose, adjust or remove the photo.
struct EditableAvatar: View {
    var size: CGFloat = 88

    @Environment(APIClient.self) private var api
    @Environment(PhotoLoader.self) private var photos
    @State private var isSaving = false
    @State private var error: Error?

    private var currentImage: UIImage? {
        api.profile?.avatarPath.flatMap { photos.cachedImage(for: $0, in: .avatars) }
    }

    var body: some View {
        AvatarSourceMenu(current: currentImage, canRemove: api.profile?.avatarPath != nil) { jpeg in
            Task { await save(jpeg) }
        } onRemove: {
            Task { await remove() }
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
        .errorAlert("Couldn’t Update Photo", error: $error)
    }

    private func save(_ jpeg: Data) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await api.setAvatar(jpeg: jpeg)
            if let path = api.profile?.avatarPath, let image = UIImage(data: jpeg) {
                photos.store(image, for: path, in: .avatars)
            }
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

    var body: some View {
        AvatarSourceMenu(current: jpeg.flatMap(UIImage.init(data:)), canRemove: jpeg != nil) { cropped in
            jpeg = cropped
        } onRemove: {
            jpeg = nil
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
    }
}

/// Take or choose a photo (or adjust the current one), then move and scale it into the circle.
/// Hands back a 512 × 512 JPEG without metadata.
struct AvatarSourceMenu<Label: View>: View {
    let current: UIImage?
    let canRemove: Bool
    let onCropped: (Data) -> Void
    let onRemove: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var cropping: CropSource?
    @State private var error: Error?

    struct CropSource: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var body: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button("Take Photo", systemImage: "camera") { showCamera = true }
            }
            Button("Choose Photo", systemImage: "photo.on.rectangle") { showPicker = true }
            if let current {
                Button("Move and Scale", systemImage: "crop") { cropping = CropSource(image: current) }
            }
            if canRemove {
                Button("Remove Photo", systemImage: "trash", role: .destructive, action: onRemove)
            }
        } label: {
            label()
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in open(data) }
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $cropping) { source in
            AvatarCropView(image: source.image) { jpeg in onCropped(jpeg) }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    open(data)
                } else {
                    error = PhotoError.unreadable
                }
                pickerItem = nil
            }
        }
        .errorAlert("Couldn’t Use Photo", error: $error)
    }

    /// Upright and at most 2048 px, so huge camera photos stay light while cropping.
    private func open(_ data: Data) {
        Task {
            if let image = await Task.detached(priority: .userInitiated, operation: { ImageProcessing.upright(data, maxPixelSize: 2048) }).value {
                cropping = CropSource(image: UIImage(cgImage: image))
            } else {
                error = PhotoError.unreadable
            }
        }
    }
}

/// "Move and Scale", like Contacts: pinch to zoom, drag to move; the circle is what's kept.
struct AvatarCropView: View {
    let image: UIImage
    let onChoose: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @State private var error: Error?

    private static let maxScale: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height) - 32
            // At scale 1 the image just covers the circle.
            let base = side / min(image.size.width, image.size.height)
            let liveScale = min(max(scale * pinch, 1), Self.maxScale)
            let liveOffset = clamped(offset + drag, scale: liveScale, base: base, side: side)

            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .frame(width: image.size.width * base * liveScale, height: image.size.height * base * liveScale)
                    .offset(liveOffset)
                    .accessibilityLabel("Photo to crop")
                // Dim everything outside the circle.
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .reverseMask { Circle().frame(width: side, height: side) }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                Circle()
                    .stroke(.white.opacity(0.7), lineWidth: 1)
                    .frame(width: side, height: side)
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in
                            scale = min(max(scale * value.magnification, 1), Self.maxScale)
                            offset = clamped(offset, scale: scale, base: base, side: side)
                        },
                    DragGesture()
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            offset = clamped(offset + value.translation, scale: scale, base: base, side: side)
                        }
                )
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    scale = 1
                    offset = .zero
                }
            }
            .safeAreaInset(edge: .top) {
                Text("Move and Scale")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Choose") {
                        do {
                            onChoose(try ImageProcessing.avatar(from: image, crop: crop(scale: scale, offset: offset, base: base, side: side)))
                            dismiss()
                        } catch {
                            self.error = PhotoError.unreadable
                        }
                    }
                    .fontWeight(.semibold)
                }
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .errorAlert("Couldn’t Use Photo", error: $error)
    }

    /// Keeps the circle covered by the image.
    private func clamped(_ offset: CGSize, scale: CGFloat, base: CGFloat, side: CGFloat) -> CGSize {
        let maxX = max(0, (image.size.width * base * scale - side) / 2)
        let maxY = max(0, (image.size.height * base * scale - side) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    /// The circle's square, in image points.
    private func crop(scale: CGFloat, offset: CGSize, base: CGFloat, side: CGFloat) -> CGRect {
        let pointsPerPixel = base * scale
        let length = side / pointsPerPixel
        let centerX = image.size.width / 2 - offset.width / pointsPerPixel
        let centerY = image.size.height / 2 - offset.height / pointsPerPixel
        return CGRect(x: centerX - length / 2, y: centerY - length / 2, width: length, height: length)
    }
}

private extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}

private extension View {
    /// Cuts `mask` out of this view.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay { mask().blendMode(.destinationOut) }
                .compositingGroup()
        }
    }
}
