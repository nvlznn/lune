import Foundation
import Testing
@testable import Swapee

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
    @Test func decodesGroupState() throws {
        let json = """
        {
          "credits": 1,
          "uploaded_today": true,
          "today_photo": {
            "photo_id": "6f1f0c4e-6d0e-4c1b-9a7e-0f1d2c3b4a59",
            "storage_path": "g/u/p.jpg",
            "taken_at": null,
            "caption": null,
            "uploaded_at": "2026-10-07T03:12:45.123456+00:00",
            "seen_by": [{"user_id": "1b1f0c4e-6d0e-4c1b-9a7e-0f1d2c3b4a59", "name": "Amy", "seen_at": "2026-10-07T03:13:00+00:00"}]
          },
          "received": [{
            "photo_id": "9a1f0c4e-6d0e-4c1b-9a7e-0f1d2c3b4a59",
            "sender_id": "1b1f0c4e-6d0e-4c1b-9a7e-0f1d2c3b4a59",
            "sender_name": "Amy",
            "storage_path": "g/a/p.jpg",
            "taken_at": "2026-10-06T21:14:00",
            "caption": "Lunch at the beach",
            "uploaded_at": "2026-10-06T14:00:00.5+00:00",
            "delivered_at": "2026-10-07T03:13:00+00:00"
          }]
        }
        """
        let state = try JSONDecoder.supabase.decode(GroupState.self, from: Data(json.utf8))
        #expect(state.uploadedToday)
        #expect(state.credits == 1)
        #expect(state.todayPhoto?.takenAt == nil)
        #expect(state.received.first?.senderName == "Amy")
        #expect(state.received.first?.takenAt != nil)
        #expect(state.received.first?.caption == "Lunch at the beach")
        #expect(state.todayPhoto?.seenBy.first?.name == "Amy")
        #expect(state.todayPhoto?.seenSummary == "Seen by Amy")
    }

    @Test func decodesClaimResults() throws {
        let waiting = try JSONDecoder.supabase.decode(ClaimResult.self, from: Data(#"{"status":"waiting"}"#.utf8))
        #expect(waiting == .waiting)
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
        let body = Data(#"{"code":"P0001","details":null,"hint":null,"message":"already_uploaded_today"}"#.utf8)
        let error = APIError(status: 400, body: body)
        #expect(error == .server(code: "already_uploaded_today"))
        #expect(error.errorDescription == "You've already sent a photo to this group today.")
    }

    @Test func mapsStorageErrors() {
        let body = Data(#"{"statusCode":"403","error":"Unauthorized","message":"new row violates row-level security policy"}"#.utf8)
        #expect(APIError(status: 400, body: body) == .http(status: 400, message: "new row violates row-level security policy"))
    }
}
