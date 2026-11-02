/// Links in peer's grouped form (0.2.19: base32 in dash-joined groups), read the way the app reads
/// them: the cases are peer's own vectors (peer/vectors/links.json), so the two readers can't drift
/// apart. A link a chat app carried may come back in capitals, without its dashes or broken over
/// lines; it reads all the same.
import Foundation
import Testing
@testable import BaudCore

struct GroupedLinkTests {
	static let valid: [(String, String, String, Double)] = [
		("https://baud.rubric.sh/add#ajtamrdfpb2gk4qaaebagbafaydqqcikbmga2dqpcaireeyu-culbogazdinryhi6d4aaaaaanlaixuccijbeeqscijbeeqsc-ijbeeqscijbeeqscijbeeqscijbeeqscilg43tonzxg43ton-zxg43tonzxg43tonzxg43tonzxg43tonzxg42ak2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfungl-abyqoeafgyqacdnyaaaaaaaaaaaaaaaaaadrabjuycuacfaq-au", "f", "Dexter", 1791003600),
		("ajwq4rdfpb2gk4xcqcmxgicnmfrqaaicamcakbqhbaequcym-buha6earcijrifiwc4mbsgq3dqor4hyaaaaaa2warpieeqsc-ijbeeqscijbeeqscijbeeqscijbeeqscijbeeqscijbeeqvl-vov2xk5lvov2xk5lvov2xk5lvov2xk5lvov2xk5lvov2xk5l-vmabjqfiaekmxeieycuacfglsedp26qrlsq6aaaaaaaaaaaa-aaaads4raeaca4tfnrqxsplior2ha4z2f4xxezlmmf4s4zly-mfwxa3dffzrw63jp", "m", "Dexter’s Mac", 1791003600),
		("https://baud.rubric.sh/add#ajzagu3bnuaacaqdaqcqmbyibefawdanbyhraeiscmkbkfqx-damrugy4dupb6aaaaaagvqel2bbeeqscijbeeqscijbeeqsc-ijbeeqscijbeeqscijbeeqscijbeftonzxg43tonzxg43ton-zxg43tonzxg43tonzxg43tonzxg43tonafnfuws2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2gtfqa4ih-cactmiabbw4aaaaaaaaaaaaaaaaaabyqau2mbkabcqiak", "r", "Sam", 1791003600),
		("baud://add#ajtaaaabaibqibiga4eascqlbqgq4dyqcejbgfavcylrqgi2-dmob2hq7aaaaaadkyb636qscijbeeqscijbeeqscijbeeqsc-ijbeeqscijbeeqscijbeeqsczxg43tonzxg43tonzxg43ton-zxg43tonzxg43tonzxg43tonzxgqa", "f", "", 1790999999),
	]

	@Test func readsPeersGroupedLinks() {
		for (input, kind, name, expires) in Self.valid {
			let l = Code.parse(input)
			#expect(l?.kind.rawValue == kind, "\(input.prefix(40))")
			#expect(l?.name == name)
			#expect(l?.expires.timeIntervalSince1970 == expires)
			#expect(l?.url.hasPrefix(kind == "m" ? "baud://link#" : "baud://add#") == true)
		}
	}

	@Test func readsThemHoweverTheyWereCopied() {
		let (input, kind, name, _) = Self.valid[0]
		let token = String(input.split(separator: "#").last!)
		for copy in [input.uppercased(), input.replacingOccurrences(of: "-", with: ""), input.replacingOccurrences(of: "-", with: "-\n"), "  " + token.replacingOccurrences(of: "-", with: " ") + "\n", "(\(input)).", "\"\(token)\","] {
			let l = Code.parse(copy)
			#expect(l?.kind.rawValue == kind && l?.name == name, "\(copy.prefix(40))")
		}
	}

	@Test func refusesBrokenOnes() {
		// Cut short, an unknown kind, a name over 64 bytes, two cases at once. (Peer refuses the rest when it redeems.)
		for input in [
			"ajtamrdfpb2gk4qaaebagbafaydqqcikbmga2dqpcaireeyu-culbogazdinryhi6d4aaaaaanlaixuccijbeeqscijbeeqsc-ijbeeqscijbeeqscijbeeqscijba",
			"aj5amrdfpb2gk4qaaebagbafaydqqcikbmga2dqpcaireeyu-culbogazdinryhi6d4aaaaaanlaixuccijbeeqscijbeeqsc-ijbeeqscijbeeqscijbeeqscijbeeqscilg43tonzxg43ton-zxg43tonzxg43tonzxg43tonzxg43tonzxg42ak2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfungl-abyqoeafgyqacdnyaaaaaaaaaaaaaaaaaadrabjuycuacfaq-au",
			"ajtecrdfpb2gk4qaaebagbafaydqqcikbmga2dqpcaireeyu-culbogazdinryhi6d4aaaaaanlaixuccijbeeqscijbeeqsc-ijbeeqscijbeeqscijbeeqscijbeeqscilg43tonzxg43ton-zxg43tonzxg43tonzxg43tonzxg43tonzxg42ak2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfungl-abyqoeafgyqacdnyaaaaaaaaaaaaaaaaaadrabjuycuacfaq-au",
			"ajtamrdfpb2gk4qaaebagbafaydqqcikbmga2dqpcaireeyu-culbogazdinryhi6d4aaaaaanlaixuccijbeeqscijbeeqsc-ijbeeqscijbeeqscijbeeqscijbeeqscilg43tonzxg43ton-zxg43tonzxg43tonzxg43tonzxg43tonzxg42ak2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2-ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfuws2ljnfungl-abyqoeafgyqacdnyaaaaaaaaaaaaaaaaaadrabjuycuacfaq-auQ",
		] {
			#expect(Code.parse(input) == nil, "\(input.prefix(40))")
		}
	}
}
