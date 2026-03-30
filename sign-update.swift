#!/usr/bin/env swift
// sign-update.swift — Signs a file with Ed25519 using CryptoKit
// Usage: swift sign-update.swift <file-to-sign> [private-key-base64]
// If no key argument, reads SIGNING_PRIVATE_KEY from .env in the script's directory.

import Foundation
import CryptoKit

func loadPrivateKeyFromEnv() -> String? {
    let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
    let envPath = (scriptDir as NSString).appendingPathComponent(".env")
    guard let contents = try? String(contentsOfFile: envPath, encoding: .utf8) else { return nil }
    for line in contents.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("SIGNING_PRIVATE_KEY=") {
            return String(trimmed.dropFirst("SIGNING_PRIVATE_KEY=".count))
        }
    }
    return nil
}

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift sign-update.swift <file> [private-key-base64]\n", stderr)
    exit(1)
}

let filePath = CommandLine.arguments[1]

let privateKeyBase64: String
if CommandLine.arguments.count >= 3 {
    privateKeyBase64 = CommandLine.arguments[2]
} else if let envKey = loadPrivateKeyFromEnv() {
    privateKeyBase64 = envKey
} else {
    fputs("Error: No private key provided and SIGNING_PRIVATE_KEY not found in .env\n", stderr)
    exit(1)
}

guard let keyData = Data(base64Encoded: privateKeyBase64) else {
    fputs("Error: Invalid base64 private key\n", stderr)
    exit(1)
}

guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
    fputs("Error: Cannot read file: \(filePath)\n", stderr)
    exit(1)
}

do {
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let signature = try privateKey.signature(for: fileData)
    print(signature.base64EncodedString())
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
