import SwiftUI

/// A friend's page: the photo, their words, who and when. The menu offers Share (to save it), Report, and Block.
struct PageRow: View {
    let entry: Entry
    /// Lets the screen refresh after blocking.
    let onBlocked: () -> Void

    @Environment(APIClient.self) private var api
    /// Kept here rather than read from the cache, which can drop it while a share sheet is open.
    @State private var image: UIImage?
    @State private var showReport = false
    @State private var confirmBlock = false
    @State private var error: Error?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemotePhoto(path: entry.storagePath) { image = $0 }
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityLabel("Photo from \(entry.name)")

            Text(entry.text)

            HStack(alignment: .center, spacing: 12) {
                AvatarView(name: entry.name, path: entry.avatarPath, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.headline)
                    Text(PhotoTime.caption(takenAt: entry.takenAt, uploadedAt: entry.createdAt))
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
        .sheet(isPresented: $showReport) { ReportSheet(entry: entry) }
        .alert("Block \(entry.name)?", isPresented: $confirmBlock) {
            Button("Block", role: .destructive) { Task { await block() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll stop being friends and won’t see each other’s pages.")
        }
        .errorAlert("Something Went Wrong", error: $error)
    }

    @ViewBuilder
    private var actions: some View {
        if let image {
            ShareLink(
                item: Image(uiImage: image),
                preview: SharePreview("From \(entry.name)", image: Image(uiImage: image))
            ) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }
        Button("Report", systemImage: "exclamationmark.bubble") { showReport = true }
        Button("Block \(entry.name)", systemImage: "hand.raised", role: .destructive) { confirmBlock = true }
    }

    private func block() async {
        do {
            try await api.block(userID: entry.userId)
            onBlocked()
        } catch {
            self.error = error
        }
    }
}
