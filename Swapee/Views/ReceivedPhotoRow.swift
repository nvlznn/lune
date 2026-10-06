import SwiftUI

/// One received photo with its sender and capture time. The menu offers Share (to save it), Report, and Block.
struct ReceivedPhotoRow: View {
    let photo: ReceivedPhoto
    /// Lets the group screen refresh after blocking.
    let onBlocked: () -> Void

    @Environment(APIClient.self) private var api
    /// Kept here rather than read from the cache, which can drop it while a share sheet is open.
    @State private var image: UIImage?
    @State private var showReport = false
    @State private var confirmBlock = false
    @State private var error: Error?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemotePhoto(path: photo.storagePath) { image = $0 }
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityLabel("Photo from \(photo.senderName)")

            if let caption = photo.caption {
                Text(caption)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("From \(photo.senderName)")
                    Text(PhotoTime.caption(takenAt: photo.takenAt, uploadedAt: photo.uploadedAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("More", systemImage: "ellipsis.circle") { actions }
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
            }
        }
        .padding(.vertical, 6)
        .contextMenu { actions }
        .sheet(isPresented: $showReport) { ReportSheet(photo: photo) }
        .alert("Block \(photo.senderName)?", isPresented: $confirmBlock) {
            Button("Block", role: .destructive) { Task { await block() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won’t receive each other’s photos in any group, and photos you’ve already received will be hidden.")
        }
        .errorAlert("Something Went Wrong", error: $error)
    }

    @ViewBuilder
    private var actions: some View {
        if let image {
            ShareLink(
                item: Image(uiImage: image),
                preview: SharePreview("From \(photo.senderName)", image: Image(uiImage: image))
            ) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }
        Button("Report", systemImage: "exclamationmark.bubble") { showReport = true }
        Button("Block \(photo.senderName)", systemImage: "hand.raised", role: .destructive) { confirmBlock = true }
    }

    private func block() async {
        do {
            try await api.block(userID: photo.senderId)
            onBlocked()
        } catch {
            self.error = error
        }
    }
}
