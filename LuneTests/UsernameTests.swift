import Testing
@testable import Lune

struct UsernameTests {
    @Test(arguments: [("@Alice.Lune", "alice.lune"), ("bob b", "bobb"), ("café-au_lait", "cafau_lait"), (String(repeating: "a", count: 40), String(repeating: "a", count: 30))])
    func typingIsCleaned(input: String, expected: String) {
        #expect(Username.clean(input) == expected)
    }

    @Test func followsInstagramRules() {
        #expect(Username.problem("alice.lune") == nil)
        #expect(Username.problem("_a_") == nil)
        #expect(Username.problem("") != nil)
        #expect(Username.problem(".alice") != nil)
        #expect(Username.problem("alice.") != nil)
        #expect(Username.problem("al..ice") != nil)
    }

    @Test func initials() {
        #expect(AvatarView.initials("Alice Lee") == "AL")
        #expect(AvatarView.initials("bob") == "B")
        #expect(AvatarView.initials("小明") == "小")
        #expect(AvatarView.initials("") == "")
    }
}
