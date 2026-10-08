import Combine
import SwiftUI

/// Tonight: your page and the letters friends sent you for today. Pages are written 20:00–04:00;
/// letters can be read until the day ends at 20:00.
struct TonightView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.scenePhase) private var scenePhase

    @State private var state: TonightState?
    @State private var error: Error?
    @State private var composing: ComposeTarget?
    @State private var showAccount = false
    @State private var sentCount = 0

    var body: some View {
        NavigationStack {
            Group {
                if let state {
                    TonightList(state: state) { composing = ComposeTarget(day: state.today) }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Tonight")
            .navigationDestination(for: Entry.self) { entry in
                if entry.userId == api.session?.userID {
                    EntryDetailView(entry: entry)
                } else {
                    LetterView(entry: entry)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Account", systemImage: "person.crop.circle") { showAccount = true }
                }
            }
            .refreshable { await refresh() }
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .luneDidChange)) { _ in
                Task { await refresh() }
            }
            // Open, close, and start a new day on time while the screen is open.
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
                guard let state else { return }
                let changes = [state.opensAt, state.closesAt, state.endsAt].compactMap(\.self)
                if changes.contains(where: { now >= $0 }) { Task { await refresh() } }
            }
            .sheet(item: $composing) { target in
                ComposeSheet(mode: .new(day: target.day)) { _ in
                    sentCount += 1
                    Task { await refresh() }
                }
            }
            .sheet(isPresented: $showAccount) { AccountSheet() }
            .errorAlert("Something Went Wrong", error: $error)
            .sensoryFeedback(.success, trigger: sentCount)
        }
    }

    private func refresh() async {
        do {
            state = try await api.tonight()
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            if state == nil { self.error = error }
        }
    }
}

/// The day the compose sheet writes.
private struct ComposeTarget: Identifiable {
    let day: String
    var id: String { day }
}

private struct TonightList: View {
    let state: TonightState
    let write: () -> Void

    var body: some View {
        List {
            Section {
                if let mine = state.mine {
                    NavigationLink(value: mine) { MyPageRow(entry: mine) }
                } else if state.open {
                    ContentUnavailableView {
                        Label {
                            Text("Tonight’s Page")
                        } icon: {
                            GhostView(mood: .awake).frame(width: 64)
                        }
                    } description: {
                        Text("One photo and a few words about your day.")
                    } actions: {
                        Button("Write Tonight’s Page", action: write)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Asleep(opensAt: state.opensAt)
                }
            } header: {
                Text(LuneDay.title(state.today))
            }

            if !state.letters.isEmpty || !state.locked.isEmpty {
                Section {
                    LetterShelf(letters: state.letters, locked: state.locked, canWrite: state.open, write: write)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Letters")
                } footer: {
                    Text("Today’s letters disappear \(Self.ending(state.endsAt)).")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// "at 8:00 PM" or "tomorrow at 8:00 PM".
    static func ending(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(date) ? "at \(time)" : "tomorrow at \(time)"
    }
}

/// Writing is closed: the sleeping ghost and when it opens.
private struct Asleep: View {
    let opensAt: Date?

    var body: some View {
        VStack(spacing: 16) {
            GhostView(mood: .asleep)
                .frame(width: 120)
                .padding(.top, 24)
            Text("Lune Is Asleep")
                .font(.title2.bold())
            if let opensAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.opening(opensAt, now: context.date))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
        .listRowBackground(Color.clear)
    }

    /// "Opens at 8:00 PM · in 6 hr, 12 min".
    static func opening(_ opensAt: Date, now: Date) -> String {
        let time = opensAt.formatted(date: .omitted, time: .shortened)
        let seconds = max(0, opensAt.timeIntervalSince(now))
        guard seconds >= 60 else { return "Opens at \(time)" }
        let remaining = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "Opens at \(time) · in \(remaining)"
    }
}

/// Your own page in a list: thumbnail, first lines, who it went to.
struct MyPageRow: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 12) {
            RemotePhoto(path: entry.storagePath, contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .lineLimit(2)
                Text("\(Image(systemName: entry.isSent ? "paperplane" : "lock")) \(entry.audienceSummary)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

extension Entry {
    /// "Sent to Alice and Bob", "Sent to Alice, Bob and 3 others", or "Only you".
    var audienceSummary: String {
        let names = (recipients ?? []).map(\.name)
        return names.isEmpty ? "Only you" : "Sent to \(Audience.names(names))"
    }
}
