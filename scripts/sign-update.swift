// Ed25519 signing for update DMGs — the same scheme Sparkle uses, without Sparkle.
//
//   swift scripts/sign-update.swift generate
//       Prints a new private key (put it in the UPDATE_SIGNING_KEY repository secret, keep no
//       other copy lying around) and writes the public key to packaging/update-public-key.txt,
//       which build-app.sh embeds in Info.plist. Refuses to overwrite an existing public key.
//
//   UPDATE_SIGNING_KEY=<base64> swift scripts/sign-update.swift sign dist/Gitunia-1.2.3.dmg
//       Writes dist/Gitunia-1.2.3.dmg.sig (base64 signature over the file's bytes).
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    let publicKeyPath = "packaging/update-public-key.txt"
    guard !FileManager.default.fileExists(atPath: publicKeyPath) else {
        fail("\(publicKeyPath) already exists — delete it first if you really mean to rotate the key.")
    }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(atPath: "packaging", withIntermediateDirectories: true)
    try (key.publicKey.rawRepresentation.base64EncodedString() + "\n")
        .write(toFile: publicKeyPath, atomically: true, encoding: .utf8)
    print("Public key written to \(publicKeyPath) (commit it).")
    print("Private key — add it as the UPDATE_SIGNING_KEY repository secret:")
    print(key.rawRepresentation.base64EncodedString())

case "sign":
    guard let path = args.dropFirst().first else { fail("usage: sign <file>") }
    guard let encoded = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
          let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("UPDATE_SIGNING_KEY is missing or not a base64 Ed25519 private key.") }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let signature = try key.signature(for: data)
    try (signature.base64EncodedString() + "\n").write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    print("Signed \(path)")

default:
    fail("usage: sign-update.swift generate | sign <file>")
}
