import Testing
@testable import Swapee

struct InviteCodeTests {
    @Test func pastedShareMessageYieldsTheCode() {
        #expect(InviteCode.clean("Join my group “Group 1” on Swapee with invite code PDT9TA") == "PDT9TA")
    }

    @Test func capitalizedWordsWinOverOtherSixLetterWords() {
        // "Swapee" also fits the alphabet; the code is the one in capitals.
        #expect(InviteCode.clean("PDT9TA is the code for Swapee") == "PDT9TA")
    }

    @Test(arguments: [("pdt9ta", "PDT9TA"), (" PDT 9TA ", "PDT9TA"), ("PDT9TAXYZ", "PDT9TA"), ("PD", "PD"), ("P0O1I", "P")])
    func typingIsUppercasedAndFiltered(input: String, expected: String) {
        #expect(InviteCode.clean(input) == expected)
    }
}
