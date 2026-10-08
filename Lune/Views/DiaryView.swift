import SwiftUI

/// Your own pages, by month. Free users see the last 30 days; Lune Premium keeps the whole diary. Export is always free.
struct DiaryView: View {
    @Environment(APIClient.self) private var api
    @Environment(LunePremium.self) private var premium

    @State private var entries: [Entry] = []
    @State private var loaded = false
    @State private var hasMore = true
    @State private var showPaywall = false
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var error: Error?

    /// Today's day key on this device, for the 30-day window.
    private var today: String { LuneDay.today }

    private var visible: [Entry] {
        premium.isActive ? entries : entries.filter { LuneDay.daysBetween($0.day, today) < LunePremium.freeDays }
    }
    private var lockedCount: Int { entries.count - visible.count }

    /// Visible pages grouped by month, newest first.
    private var months: [(title: String, entries: [Entry])] {
        var result: [(title: String, entries: [Entry])] = []
        for entry in visible {
            let title = LuneDay.month(entry.day)
            if result.last?.title == title {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append((title, [entry]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(months, id: \.title) { month in
                    Section(month.title) {
                        ForEach(month.entries) { entry in
                            NavigationLink(value: entry) { DiaryRow(entry: entry) }
                        }
                    }
                }

                if lockedCount > 0 {
                    Section {
                        Button("Unlock Older Pages") { showPaywall = true }
                    } footer: {
                        Text("Your pages from more than \(LunePremium.freeDays) days ago are kept safe. Lune Premium lets you read your whole diary.")
                    }
                } else if hasMore && loaded && !entries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await loadMore() }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if loaded && entries.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No Pages Yet")
                        } icon: {
                            GhostView(mood: .awake).frame(width: 72)
                        }
                    } description: {
                        Text("Every page you write is kept here.")
                    }
                }
            }
            .navigationTitle("Diary")
            .navigationDestination(for: Entry.self) { entry in
                EntryDetailView(entry: entry)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if exporting {
                        ProgressView()
                    } else {
                        Button("Export", systemImage: "square.and.arrow.up") { Task { await export() } }
                            .disabled(entries.isEmpty)
                    }
                }
            }
            .refreshable { await reload() }
            // Reload whenever the tab is shown, and when a page is written or edited elsewhere.
            .onAppear { Task { await reload() } }
            .onReceive(NotificationCenter.default.publisher(for: .luneDidChange)) { _ in
                Task { await reload() }
            }
            .sheet(isPresented: $showPaywall) { PaywallSheet() }
            .sheet(item: $exportURL) { url in ActivityView(items: [url]) }
            .errorAlert("Something Went Wrong", error: $error)
        }
    }

    private func reload() async {
        do {
            let page = try await api.myEntries()
            // Keep pages already loaded further back when only the newest ones changed.
            let older = entries.filter { entry in !page.contains { $0.day == entry.day } && entry.day < (page.last?.day ?? "") }
            entries = page + older
            hasMore = page.count == 60
            loaded = true
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }

    private func loadMore() async {
        guard let last = entries.last else { return }
        do {
            let page = try await api.myEntries(before: last.day)
            entries += page
            hasMore = page.count == 60
        } catch {
            hasMore = false
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        do {
            exportURL = try await DiaryExport.make(api: api)
        } catch {
            self.error = error
        }
    }
}

private struct DiaryRow: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 12) {
            RemotePhoto(path: entry.storagePath, contentMode: .fill)
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(LuneDay.title(entry.day))
                Text(entry.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Your whole diary as a zip: a Markdown file plus the photos.
enum DiaryExport {
    static func make(api: APIClient) async throws -> URL {
        let entries = try await api.exportEntries()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "Lune Export \(UUID().uuidString)")
        let folder = root.appending(path: "Lune Diary")
        let photos = folder.appending(path: "photos")
        try fileManager.createDirectory(at: photos, withIntermediateDirectories: true)

        var markdown = "# Lune Diary\n\n"
        for entry in entries {
            let file = "\(entry.day).jpg"
            try await api.downloadImage(at: entry.storagePath).write(to: photos.appending(path: file))
            markdown += "## \(LuneDay.title(entry.day)), \(entry.day.prefix(4))\n\n![](photos/\(file))\n\n\(entry.text)\n\n"
        }
        try markdown.write(to: folder.appending(path: "Diary.md"), atomically: true, encoding: .utf8)

        // Reading a folder "for uploading" hands back a zip of it.
        let zip = root.appending(path: "Lune Diary.zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipped in
            do { try fileManager.copyItem(at: zipped, to: zip) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return zip
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// The system share sheet for files.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
