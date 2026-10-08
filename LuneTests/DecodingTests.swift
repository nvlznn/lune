import Foundation
import Testing
@testable import Lune

struct PostgresDateTests {
    @Test func parsesTimestamptzWithMicroseconds() throws {
        let date = try #require(PostgresDate.parse("2026-10-07T03:12:45.123456+00:00"))
        #expect(abs(date.timeIntervalSince1970 - 1_791_342_765.123456) < 0.001)
    }

    @Test func appliesOffsets() {
        #expect(PostgresDate.parse("2026-10-07T11:12:45+08:00") == PostgresDate.parse("2026-10-07T03:12:45Z"))
        #expect(PostgresDate.parse("2026-10-07T11:12:45+0800") == PostgresDate.parse("2026-10-07T03:12:45Z"))
    }

    @Test func readsBareTimestampAsLocalTime() throws {
        let date = try #require(PostgresDate.parse("2026-10-06T21:14:00"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(parts == DateComponents(year: 2026, month: 10, day: 6, hour: 21, minute: 14))
    }

    @Test(arguments: ["", "yesterday", "2026-10-06", "2026-10-06T21:14"])
    func rejectsOtherFormats(_ string: String) {
        #expect(PostgresDate.parse(string) == nil)
    }
}

struct ResponseDecodingTests {
    @Test func decodesTonight() throws {
        let page = { (name: String, extra: String) in """
            {"entry_id": "\(UUID().uuidString)", "user_id": "1b1f0c4e-6d0e-4c1b-9a7e-0f1d2c3b4a59", "name": "\(name)",
             "username": "\(name.lowercased())", "avatar_path": null, "day": "2026-10-07", "storage_path": "u/p.jpg",
             "text": "Long day.\\nGood dinner.", "taken_at": "2026-10-06T21:14:00",
             "created_at": "2026-10-07T13:12:45.123456+00:00", "edited_at": null, \(extra)}
            """ }
        let json = """
        {
          "today": "2026-10-07", "open": true, "opens_at": null, "closes_at": "2026-10-07T20:00:00+00:00",
          "ends_at": "2026-10-08T12:00:00+00:00",
          "mine": \(page("Me", #""sent_at": "2026-10-07T13:12:45+00:00", "recipients": [{"user_id": "2b1f0c4e-6d0e-4c1b-9a7e-0f1d2c3b4a59", "name": "Amy", "username": "amy", "avatar_path": null}]"#)),
          "letters": [\(page("Amy", #""sent_at": "2026-10-07T13:00:00+00:00", "recipients": null"#))],
          "locked": []
        }
        """
        let state = try JSONDecoder.supabase.decode(TonightState.self, from: Data(json.utf8))
        #expect(state.open)
        #expect(state.mine?.isSent == true)
        #expect(state.mine?.audienceSummary == "Sent to Amy")
        #expect(state.mine?.text == "Long day.\nGood dinner.")
        #expect(state.letters.first?.username == "amy")
        #expect(state.letters.first?.recipients == nil)
        #expect(state.closesAt != nil)
    }

    @Test func decodesLockedLetters() throws {
        let json = """
        {"today": "2026-10-07", "open": false, "opens_at": "2026-10-08T12:00:00+00:00", "closes_at": null,
         "ends_at": "2026-10-08T12:00:00+00:00", "mine": null, "letters": [],
         "locked": [{"user_id": "2b1f0c4e-6d0e-4c1b-9a7e-0f1d2c3b4a59", "name": "Amy", "username": "amy",
                     "avatar_path": null, "sent_at": "2026-10-07T13:00:00+00:00"}]}
        """
        let state = try JSONDecoder.supabase.decode(TonightState.self, from: Data(json.utf8))
        #expect(state.locked.map(\.username) == ["amy"])
        #expect(state.mine == nil)
    }

    @Test func summarizesAudiences() {
        let friends = ["Amy", "Ben", "Cara", "Dan"].map {
            Friend(userId: UUID(), name: $0, username: nil, avatarPath: nil, since: .now)
        }
        let close = FriendGroup(id: UUID(), name: "Close", memberIds: [friends[0].userId, friends[1].userId])
        let all = Set(friends.map(\.userId))
        #expect(Audience.summary(all, friends: friends, groups: [close]) == "All Friends (4)")
        #expect(Audience.summary([], friends: friends, groups: [close]) == "Only Me")
        #expect(Audience.summary(Set(close.memberIds), friends: friends, groups: [close]) == "Close")
        #expect(Audience.summary([friends[2].userId], friends: friends, groups: [close]) == "Cara")
        #expect(Audience.question(all, friends: friends, groups: []) == "Send to All 4 Friends?")
        #expect(Audience.names(["A", "B", "C", "D", "E"]) == "A, B and 3 others")
    }

    @Test func decodesFriendResults() throws {
        let result = try JSONDecoder.supabase.decode(AddFriendResult.self, from: Data(#"{"status":"already_friends","name":"Amy"}"#.utf8))
        #expect(result == AddFriendResult(status: .alreadyFriends, name: "Amy"))
        let notFound = try JSONDecoder.supabase.decode(AddFriendResult.self, from: Data(#"{"status":"not_found"}"#.utf8))
        #expect(notFound.status == .notFound && notFound.name == nil)
    }

    @Test func decodesAuthResponseAndStoredSession() throws {
        let response = """
        {"access_token":"a","refresh_token":"r","expires_at":1791342765,"expires_in":3600,
         "user":{"id":"1b1f0c4e-6d0e-4c1b-9a7e-0f1d2c3b4a59"}}
        """
        let session = try JSONDecoder().decode(AuthSession.self, from: Data(response.utf8))
        #expect(session.userID == UUID(uuidString: "1b1f0c4e-6d0e-4c1b-9a7e-0f1d2c3b4a59"))
        #expect(session.expiresAt == Date(timeIntervalSince1970: 1_791_342_765))

        let roundTripped = try JSONDecoder().decode(AuthSession.self, from: JSONEncoder().encode(session))
        #expect(roundTripped == session)
    }

    @Test func mapsRPCErrorCodes() {
        let body = Data(#"{"code":"P0001","details":null,"hint":null,"message":"closed"}"#.utf8)
        let error = APIError(status: 400, body: body)
        #expect(error == .server(code: "closed"))
        #expect(error.errorDescription == "Lune is closed. It opens at 8:00 PM.")
    }

    @Test func mapsStorageErrors() {
        let body = Data(#"{"statusCode":"403","error":"Unauthorized","message":"new row violates row-level security policy"}"#.utf8)
        #expect(APIError(status: 400, body: body) == .http(status: 400, message: "new row violates row-level security policy"))
    }
}

struct LuneDayTests {
    @Test func formatsDays() {
        #expect(LuneDay.previous("2026-10-01") == "2026-09-30")
        #expect(LuneDay.daysBetween("2026-09-07", "2026-10-07") == 30)
        #expect(LuneDay.title("2026-10-07").contains("October"))
        #expect(LuneDay.month("2026-10-07").contains("2026"))
    }
}
