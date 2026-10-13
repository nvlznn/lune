import SwiftUI

/// Size of every card on the letter shelf, so a row of letters lines up.
enum LetterCardSize {
    static let width: CGFloat = 240
    static let height: CGFloat = 340
    static let photoHeight: CGFloat = 180
}

/// Letters side by side; each leads to the full letter.
struct LetterShelf: View {
    let letters: [Entry]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(letters) { entry in
                    NavigationLink(value: entry) {
                        LetterCard(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

/// Avatar and @username at the top of a letter.
struct LetterHeader: View {
    let name: String
    let username: String?
    let avatarPath: String?
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(name: name, path: avatarPath, size: size)
            Text(username.map { "@\($0)" } ?? name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// A letter on the shelf: who, the photo, the first lines.
private struct LetterCard: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LetterHeader(name: entry.name, username: entry.username, avatarPath: entry.avatarPath)
            Color.clear
                .frame(height: LetterCardSize.photoHeight)
                .overlay { RemotePhoto(path: entry.storagePath, contentMode: .fill) }
                .clipShape(.rect(cornerRadius: 10))
            Text(entry.text)
                .font(.subheadline)
                .lineLimit(5)
            Spacer(minLength: 0)
        }
        .letterCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Letter from \(entry.name)")
    }
}

private extension View {
    func letterCard() -> some View {
        padding(12)
            .frame(width: LetterCardSize.width, height: LetterCardSize.height, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
    }
}

/// A friend's letter in full. The menu offers Share (to save it), Report, and Block.
struct LetterView: View {
    let entry: Entry

    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    /// Kept here rather than read from the cache, which can drop it while a share sheet is open.
    @State private var image: UIImage?
    @State private var showReport = false
    @State private var confirmBlock = false
    @State private var error: Error?

    var body: some View {
        List {
            Section {
                LetterHeader(name: entry.name, username: entry.username, avatarPath: entry.avatarPath, size: 36)
                RemotePhoto(path: entry.storagePath) { image = $0 }
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 10))
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .accessibilityLabel("Photo from \(entry.name)")
                Text(entry.text)
                    .textSelection(.enabled)
            } footer: {
                Text(PhotoTime.caption(takenAt: entry.takenAt, uploadedAt: entry.createdAt))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis.circle") { actions }
            }
        }
        .sheet(isPresented: $showReport) { ReportSheet(entry: entry) }
        .alert("Block \(entry.name)?", isPresented: $confirmBlock) {
            Button("Block", role: .destructive) { Task { await block() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll stop being friends and won’t get each other’s pages.")
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
            NotificationCenter.default.post(name: .luneDidChange, object: nil)
            dismiss()
        } catch {
            self.error = error
        }
    }
}
