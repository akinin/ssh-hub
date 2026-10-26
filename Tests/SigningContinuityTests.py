#!/usr/bin/env python3
"""Owned temporary apps/keychain only; never reads application/user credentials."""
import os
import pathlib
import plistlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = r'''
import Foundation
import Security

#if SECOND_BUILD
let revision = "second"
#else
let revision = "first"
#endif
func check(_ result: OSStatus, _ operation: String) {
    guard result == errSecSuccess else {
        fputs("\(operation): OSStatus \(result)\n", stderr)
        exit(2)
    }
}
let mode = CommandLine.arguments[1]
let path = CommandLine.arguments[2]
let service = "ssh-hub-owned-signing-fixture"
let account = "fixture"
let secret = "synthetic-fixture-only"
var keychain: SecKeychain?
check(SecKeychainSetUserInteractionAllowed(false), "disable UI")
if mode == "create" {
    var searchList: CFArray?
    check(SecKeychainCopySearchList(&searchList), "save search list")
    guard let searchList else { exit(6) }
    let fixturePassword = "owned-fixture-password"
    let result = fixturePassword.withCString {
        SecKeychainCreate(path, UInt32(fixturePassword.utf8.count), $0, false, nil, &keychain)
    }
    // Creating a keychain may add it to the list. Restore before any assertions.
    check(SecKeychainSetSearchList(searchList), "restore search list")
    check(result, "create fixture keychain")
    check(SecKeychainAddGenericPassword(keychain, UInt32(service.utf8.count), service,
        UInt32(account.utf8.count), account, UInt32(secret.utf8.count), secret, nil), "add fixture")
} else {
    check(SecKeychainOpen(path, &keychain), "open fixture keychain")
    if mode == "cleanup" {
        check(SecKeychainDelete(keychain), "delete fixture keychain")
    } else {
        var size: UInt32 = 0
        var data: UnsafeMutableRawPointer?
        let result = SecKeychainFindGenericPassword(keychain, UInt32(service.utf8.count), service,
            UInt32(account.utf8.count), account, &size, &data, nil)
        if mode == "denied" {
            guard result == errSecInteractionNotAllowed || result == errSecAuthFailed else {
                fputs("unexpected access status: \(result)\n", stderr); exit(3)
            }
        } else {
            check(result, "read fixture without interaction")
            guard let data, Data(bytes: data, count: Int(size)) == Data(secret.utf8) else { exit(4) }
        }
        if let data { SecKeychainItemFreeContent(nil, data) }
    }
}
print("fixture \(revision): \(mode) passed")
'''


def run(*args, env=None, ok=True):
    result = subprocess.run(args, cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if ok and result.returncode:
        raise RuntimeError(result.stdout)
    return result


with tempfile.TemporaryDirectory(prefix="ssh-hub-signing-test-", dir="/private/tmp") as directory:
    temp = pathlib.Path(directory)
    source = temp / "Fixture.swift"
    source.write_text(SOURCE)
    apps = []
    for name, defines in (("first", []), ("second", ["-DSECOND_BUILD"])):
        app = temp / name / "SSH Hub.app"
        macos = app / "Contents/MacOS"
        macos.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.olshaniki.ssh-aliases",
            "CFBundleExecutable": "SSHHub", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1" if name == "first" else "2",
        }))
        run("xcrun", "swiftc", *defines, str(source), "-framework", "Security",
            "-o", str(macos / "SSHHub"))
        run("zsh", "sign-app.sh", str(app))
        apps.append(app)
    first, second = apps
    requirement = run("codesign", "-d", "-r-", str(first)).stdout.split("designated => ")[1]
    assert "cdhash" not in requirement
    assert requirement == run("codesign", "-d", "-r-", str(second)).stdout.split("designated => ")[1]
    assert (first / "Contents/MacOS/SSHHub").read_bytes() != (second / "Contents/MacOS/SSHHub").read_bytes()
    keychain = temp / "fixture.keychain-db"
    first_binary = str(first / "Contents/MacOS/SSHHub")
    second_binary = str(second / "Contents/MacOS/SSHHub")
    try:
        run(first_binary, "create", str(keychain))
        run(second_binary, "read", str(keychain))
        # Same bundle ID without the signer must not gain access.
        run("zsh", "sign-app.sh", str(second), env={**os.environ, "SSH_HUB_SIGN_IDENTITY": "-"})
        run(second_binary, "denied", str(keychain))
    finally:
        if keychain.exists():
            run(first_binary, "cleanup", str(keychain))
    missing = run("zsh", "sign-app.sh", "--check", ok=False,
                  env={**os.environ, "SSH_HUB_SIGN_IDENTITY": "0" * 40})
    assert missing.returncode != 0 and "ad-hoc автоматически не используется" in missing.stdout
    # Altering sealed content must be rejected before packaging.
    (first / "Contents/Info.plist").write_bytes((second / "Contents/Info.plist").read_bytes())
    assert run("zsh", "sign-app.sh", "--verify", str(first), ok=False).returncode != 0
    print("Signing continuity: changed builds share a requirement; Keychain read needs no UI; "
          "ad-hoc access, missing identity and tampered bundle rejected.")
