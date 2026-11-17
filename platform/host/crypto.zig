//! Native equivalents of the browser's closed WebCrypto vocabulary. These
//! primitives have no application policy: the Roc requests choose parameters,
//! and the spec runner supplies deterministic random bytes separately. Keys
//! remain in the native host's typed handle heap, never in result bytes.
const std = @import("std");
const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const Key = [Aes.key_length]u8;
pub const Iv = [Aes.nonce_length]u8;
pub const Hash = enum(u8) { sha256 = 1, sha384 = 2, sha512 = 3 };
pub const KdfHash = enum(u8) { sha256 = 1, sha512 = 3 };
pub const tag_length = Aes.tag_length;

/// PBKDF2-HMAC over the exact UTF-8 password and salt bytes. The caller
/// validates the deployment's iteration ceiling before doing this work.
pub fn derive(password: []const u8, salt: []const u8, iterations: u32, hash: KdfHash) error{InvalidIterations}!Key {
    if (iterations == 0) return error.InvalidIterations;
    var key: Key = undefined;
    switch (hash) {
        .sha256 => std.crypto.pwhash.pbkdf2(&key, password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha256) catch unreachable,
        .sha512 => std.crypto.pwhash.pbkdf2(&key, password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha512) catch unreachable,
    }
    return key;
}

/// Write ciphertext followed by its full 128-bit GCM tag, exactly the layout
/// WebCrypto returns. The output belongs to the caller and has plaintext.len
/// plus tag_length bytes; the IV was drawn separately for this one seal.
pub fn encrypt(output: []u8, key: Key, iv: Iv, plaintext: []const u8, associated: []const u8) void {
    std.debug.assert(output.len == plaintext.len + tag_length);
    var tag: [tag_length]u8 = undefined;
    Aes.encrypt(output[0..plaintext.len], &tag, plaintext, associated, iv, key);
    @memcpy(output[plaintext.len..], &tag);
}

/// Authenticate before exposing any plaintext. A wrong password-derived key,
/// IV, context, tag or ciphertext has the same AuthenticationFailed outcome.
/// The caller owns an output of ciphertext.len minus tag_length bytes.
pub fn decrypt(output: []u8, key: Key, iv: Iv, ciphertext: []const u8, associated: []const u8) error{AuthenticationFailed}!void {
    if (ciphertext.len < tag_length) return error.AuthenticationFailed;
    const length = ciphertext.len - tag_length;
    std.debug.assert(output.len == length);
    Aes.decrypt(output, ciphertext[0..length], ciphertext[length..][0..tag_length].*, associated, iv, key) catch {
        std.crypto.secureZero(u8, output);
        return error.AuthenticationFailed;
    };
}

/// Digest the exact input bytes into a correctly sized caller-owned buffer.
pub fn digest(output: []u8, hash: Hash, bytes: []const u8) void {
    switch (hash) {
        .sha256 => std.crypto.hash.sha2.Sha256.hash(bytes, output[0..32], .{}),
        .sha384 => std.crypto.hash.sha2.Sha384.hash(bytes, output[0..48], .{}),
        .sha512 => std.crypto.hash.sha2.Sha512.hash(bytes, output[0..64], .{}),
    }
}

/// Drop the host's only key material when its Roc handle's last reference is
/// drained, including a key whose returned handle the application discarded.
pub fn erase(key: *Key) void {
    std.crypto.secureZero(u8, key);
}

test "PBKDF2 SHA-256 and SHA-512 match published one-iteration vectors" {
    const sha256 = try derive("password", "salt", 1, .sha256);
    const sha512 = try derive("password", "salt", 1, .sha512);
    try std.testing.expectEqualStrings("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", &std.fmt.bytesToHex(sha256, .lower));
    try std.testing.expectEqualStrings("867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252", &std.fmt.bytesToHex(sha512, .lower));
    try std.testing.expectError(error.InvalidIterations, derive("password", "salt", 0, .sha256));
}

test "AES-256-GCM matches the NIST zero-key zero-IV vector and WebCrypto tag layout" {
    const key: Key = @splat(0);
    const iv: Iv = @splat(0);
    const plaintext: [16]u8 = @splat(0);
    var sealed: [32]u8 = undefined;
    encrypt(&sealed, key, iv, &plaintext, "");
    try std.testing.expectEqualStrings("cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919", &std.fmt.bytesToHex(sealed, .lower));
    var opened: [16]u8 = undefined;
    try decrypt(&opened, key, iv, &sealed, "");
    try std.testing.expectEqualSlices(u8, &plaintext, &opened);
    sealed[0] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, decrypt(&opened, key, iv, &sealed, ""));
    try std.testing.expectEqualSlices(u8, &plaintext, &opened);
}

test "empty plaintext still authenticates and associated data is bound to the seal" {
    const key = try derive("p\x00ass", "s\x00alt", 2, .sha256);
    const iv: Iv = @splat(7);
    var sealed: [tag_length]u8 = undefined;
    encrypt(&sealed, key, iv, "", "project");
    var empty: [0]u8 = .{};
    try decrypt(&empty, key, iv, &sealed, "project");
    try std.testing.expectError(error.AuthenticationFailed, decrypt(&empty, key, iv, &sealed, "another project"));
    try std.testing.expectError(error.AuthenticationFailed, decrypt(&empty, key, iv, "short", "project"));
}

test "digests match SHA-2 known answers and erasing clears the held material" {
    var sha256: [32]u8 = undefined;
    var sha384: [48]u8 = undefined;
    var sha512: [64]u8 = undefined;
    digest(&sha256, .sha256, "abc");
    digest(&sha384, .sha384, "abc");
    digest(&sha512, .sha512, "abc");
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &std.fmt.bytesToHex(sha256, .lower));
    try std.testing.expectEqualStrings("cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7", &std.fmt.bytesToHex(sha384, .lower));
    try std.testing.expectEqualStrings("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", &std.fmt.bytesToHex(sha512, .lower));
    erase(&sha256);
    try std.testing.expectEqualSlices(u8, &@as(Key, @splat(0)), &sha256);
}
