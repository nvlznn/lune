import Combine
import SwiftUI

/// Tonight: your page, friends' pages for tonight and last night. Open 20:00–04:00; asleep otherwise.
struct TonightView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.scenePhase) private var scenePhase

    @State private var state: TonightState?
    @State private var error: Error?
    @State private var composing: ComposeTarget?
    @State private var showAccount = false
    @State private var sentCount = 0

    /// Which day the compose sheet writes.
    struct ComposeTarget: Identifiable {
        let day: String
        let isYesterday: Bool
        var id: String { day }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let state {
                    if state.open {
                        OpenList(state: state, compose: { composing = $0 }, refresh: { await refresh() })
                    } else {
                        ClosedList(state: state)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Tonight")
            .navigationDestination(for: Entry.self) { entry in
                EntryDetailView(entry: entry, canEdit: state?.open ?? false)
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
            // Wake up (or fall asleep) on time while the screen is open.
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
                guard let state else { return }
                if let opensAt = state.opensAt, now >= opensAt { Task { await refresh() } }
                if let closesAt = state.closesAt, now >= closesAt { Task { await refresh() } }
            }
            .sheet(item: $composing) { target in
                ComposeSheet(day: target.day, isYesterday: target.isYesterday) {
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

// MARK: - Open

private struct OpenList: View {
    let state: TonightState
    let compose: (TonightView.ComposeTarget) -> Void
    let refresh: () async -> Void

    var body: some View {
        List {
            if let tonight = state.tonight {
                Section {
                    if let mine = tonight.mine {
                        NavigationLink(value: mine) { MyPageRow(entry: mine) }
                    } else {
                        ContentUnavailableView {
                            Label {
                                Text("Tonight’s Page")
                            } icon: {
                                GhostView(mood: .awake).frame(width: 64)
                            }
                        } description: {
                            Text("One photo and a few words about your day.")
                        } actions: {
                            Button("Write Tonight’s Page") {
                                compose(.init(day: tonight.day, isYesterday: false))
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } header: {
                    Text(LuneDay.title(tonight.day))
                }
            }

            if let lastNight = state.lastNight, lastNight.mine == nil {
                Section {
                    Button("Write Yesterday’s Page") {
                        compose(.init(day: lastNight.day, isYesterday: true))
                    }
                } footer: {
                    Text("Missed last night? You can still write it tonight.")
                }
            }

            if let tonight = state.tonight {
                FriendsSection(title: "Friends Tonight", day: tonight, refresh: refresh)
            }
            if let lastNight = state.lastNight {
                FriendsSection(title: "Last Night", day: lastNight, refresh: refresh)
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// Friends' pages for a day; pages you can't read yet show who wrote them.
private struct FriendsSection: View {
    let title: String
    let day: TonightState.DayState
    let refresh: () async -> Void

    var body: some View {
        if !day.friends.isEmpty || !day.lockedWriters.isEmpty {
            Section(title) {
                ForEach(day.friends) { entry in
                    PageRow(entry: entry) { Task { await refresh() } }
                }
                if !day.lockedWriters.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(day.lockedWriters.formatted(.list(type: .and))) wrote")
                            Text("Write your page to read theirs.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Your own page in the list: thumbnail, first lines, who has seen it.
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
                Text(entry.seenSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

extension Entry {
    /// "Seen by Bob and Carol", "Seen by 5 friends", or "Not seen yet".
    var seenSummary: String {
        let viewers = seenBy ?? []
        switch viewers.count {
        case 0: return "Not seen yet"
        case 1...3: return "Seen by \(viewers.map(\.name).formatted(.list(type: .and)))"
        default: return "Seen by \(viewers.count) friends"
        }
    }
}

// MARK: - Closed

private struct ClosedList: View {
    let state: TonightState

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    GhostView(mood: .asleep)
                        .frame(width: 120)
                        .padding(.top, 24)
                    Text("Lune Is Asleep")
                        .font(.title2.bold())
                    if let opensAt = state.opensAt {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(Self.opening(opensAt, now: context.date))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if let writers = state.lastNight?.writers, !writers.isEmpty {
                        Text("Last night, \(writers.formatted(.list(type: .and))) wrote.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
                .listRowBackground(Color.clear)
            }

            let mine = state.days.compactMap(\.mine)
            if !mine.isEmpty {
                Section("Your Pages") {
                    ForEach(mine) { entry in
                        NavigationLink(value: entry) { MyPageRow(entry: entry) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
