/// Links in peer's dotless form (one base64url token), read the way the app reads them: the
/// cases are peer's own vectors (peer/vectors/links.json), so the two readers can't drift apart.
import Foundation
import Testing
@testable import BaudCore

struct DotlessLinkTests {
	static let valid: [(String, String, String, Double)] = [
		("https://baud.rubric.sh/add#AWYGRGV4dGVyAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8AAAAAasCL0EJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZDtyZWxheT1odHRwOi8vMjAzLjAuMTEzLjc6NDEwMTsyMDMuMC4xMTMuNzo0MTAx", "f", "Dexter", 1791003600),
		("AW0ORGV4dGVy4oCZcyBNYWMAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHwAAAABqwIvQQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiOzE5Mi4xNjguMS4yMDo1MjExMztbZmQ3YToxMTVjOmExZTA6OjFdOjUyMTEz", "m", "Dexter’s Mac", 1791003600),
		("baud://add#AWYAAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8AAAAAasB9v0JCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYmFiYWJhYg", "f", "", 1790999999),
	]

	@Test func readsPeersDotlessLinks() {
		for (input, kind, name, expires) in Self.valid {
			let l = Code.parse(input)
			#expect(l?.kind.rawValue == kind, "\(input.prefix(40))")
			#expect(l?.name == name)
			#expect(l?.expires.timeIntervalSince1970 == expires)
			#expect(l?.url.hasPrefix(kind == "m" ? "baud://link#" : "baud://add#") == true)
		}
	}

	@Test func refusesBrokenOnes() {
		// Cut short, a wrong version, an unknown kind. (Peer refuses the rest when it redeems.)
		for input in [
			"AWYGRGV4dGVyAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8AAAAAasCL0EJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI",
			"AmYGRGV4dGVyAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8AAAAAasCL0EJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZDtyZWxheT1odHRwOi8vMjAzLjAuMTEzLjc6NDEwMTsyMDMuMC4xMTMuNzo0MTAx",
			"AXoGRGV4dGVyAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8AAAAAasCL0EJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZGNkY2RjZDtyZWxheT1odHRwOi8vMjAzLjAuMTEzLjc6NDEwMTsyMDMuMC4xMTMuNzo0MTAx",
		] {
			#expect(Code.parse(input) == nil, "\(input.prefix(40))")
		}
	}
}
