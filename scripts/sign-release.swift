// Signs the site's release record (site/releases.json) so the apps take an update only from us,
// even if the site were changed by someone else. P-256 ECDSA over a fixed text built from the
// record's fields; Apple's CryptoKit and Android's built-in Signature both check it.
//   swift scripts/sign-release.swift site/releases.json   → adds "sig" to the record
//   swift scripts/sign-release.swift --new-key            → makes the key (once), prints the public half
// The private key lives only in the login keychain ("baud release record key", account baud-release).
import CryptoKit
import Foundation

func keychain(_ args: [String]) -> (Int32, String) {
	let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security"); p.arguments = args
	let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
	try! p.run(); p.waitUntilExit()
	return (p.terminationStatus, String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))
}
let service = "baud release record key", account = "baud-release"
let args = CommandLine.arguments.dropFirst()

if args.first == "--new-key" {
	guard keychain(["find-generic-password", "-a", account, "-s", service]).0 != 0 else { print("a key already exists; not replacing it"); exit(1) }
	let key = P256.Signing.PrivateKey()
	guard keychain(["add-generic-password", "-a", account, "-s", service, "-w", key.rawRepresentation.base64EncodedString()]).0 == 0 else { print("couldn't store the key"); exit(1) }
	print(key.publicKey.derRepresentation.base64EncodedString())
	exit(0)
}

guard let path = args.first else { print("usage: sign-release.swift site/releases.json | --new-key"); exit(2) }
let (status, secret) = keychain(["find-generic-password", "-a", account, "-s", service, "-w"])
guard status == 0, let raw = Data(base64Encoded: secret), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) else { print("no release key in the keychain"); exit(1) }
let url = URL(fileURLWithPath: path)
var record = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
let android = record["android"] as? [String: Any] ?? [:]
// The signed text: the same fields, in the same order, on every platform.
let text = ["baud release 1", record["version"], record["dmg"], record["sha256"], android["version"], android["apk"], android["sha256"]]
	.map { ($0 as? String) ?? "" }.joined(separator: "\n")
record["sig"] = try! key.signature(for: Data(text.utf8)).derRepresentation.base64EncodedString()
let out = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
try! out.write(to: url)
print("signed \(record["version"] ?? "?")")
