import SwiftUI

/// The photo you sent today, and who has received it.
struct OwnPhotoView: View {
    let groupID: UUID

    @Environment(APIClient.self) private var api
    @State private var photo: OwnPhoto
    @State private var error: Error?

    init(groupID: UUID, photo: OwnPhoto) {
        self.groupID = groupID
        _photo = State(initialValue: photo)
    }

    var body: some View {
        List {
            Section {
                RemotePhoto(path: photo.storagePath)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 10))
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .accessibilityLabel("Your photo")
                if let caption = photo.caption {
                    Text(caption)
                }
            } footer: {
                Text(PhotoTime.caption(takenAt: photo.takenAt, uploadedAt: photo.uploadedAt))
            }

            Section {
                if photo.seenBy.isEmpty {
                    Text("No one has received it yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(photo.seenBy) { viewer in
                    LabeledContent(viewer.name, value: PhotoTime.standalone(viewer.seenAt))
                }
            } header: {
                Text("Seen By")
            } footer: {
                Text("Friends receive your photo after they send one of their own.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Today’s Photo")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .errorAlert("Something Went Wrong", error: $error)
    }

    private func reload() async {
        do {
            if let latest = try await api.groupState(groupID).todayPhoto {
                photo = latest
            }
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }
}

extension OwnPhoto {
    /// "Seen by Bob and Carol", "Seen by 5 people", or "Not seen yet".
    var seenSummary: String {
        switch seenBy.count {
        case 0: "Not seen yet"
        case 1...3: "Seen by \(seenBy.map(\.name).formatted(.list(type: .and)))"
        default: "Seen by \(seenBy.count) people"
        }
    }
}
