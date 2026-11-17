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
/// Invalid UTF-8 is rejected before PBKDF2, never repaired or normalized.
pub fn derive(password: []const u8, salt: []const u8, iterations: u32, hash: KdfHash) error{ InvalidIterations, InvalidPasswordUtf8 }!Key {
    try validatePassword(password);
    if (iterations == 0) return error.InvalidIterations;
    var key: Key = undefined;
    switch (hash) {
        .sha256 => std.crypto.pwhash.pbkdf2(&key, password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha256) catch unreachable,
        .sha512 => std.crypto.pwhash.pbkdf2(&key, password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha512) catch unreachable,
    }
    return key;
}

/// Check the wire's password invariant before parameter refusals or native
/// cryptographic work. Empty UTF-8 is valid; no text conversion changes bytes.
pub fn validatePassword(password: []const u8) error{InvalidPasswordUtf8}!void {
    if (!std.unicode.utf8ValidateSlice(password)) return error.InvalidPasswordUtf8;
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

/// Deterministic bytes for the native spec backend alone. The browser manual
/// backend implements this same stream; production never calls this function.
pub fn specRandom(output: []u8, offset: u64) void {
    const prefix = "roc-signals spec crypto\x00";
    var material: [prefix.len + 8]u8 = undefined;
    @memcpy(material[0..prefix.len], prefix);
    var position = offset;
    var written: usize = 0;
    while (written < output.len) {
        std.mem.writeInt(u64, material[prefix.len..][0..8], position / 32, .little);
        var block: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&material, &block, .{});
        const start: usize = @intCast(position % 32);
        const count = @min(output.len - written, 32 - start);
        @memcpy(output[written..][0..count], block[start..][0..count]);
        written += count;
        position += count;
    }
}

test "PBKDF2 SHA-256 and SHA-512 match published one-iteration vectors" {
    const sha256 = try derive("password", "salt", 1, .sha256);
    const sha512 = try derive("password", "salt", 1, .sha512);
    try std.testing.expectEqualStrings("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", &std.fmt.bytesToHex(sha256, .lower));
    try std.testing.expectEqualStrings("867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252", &std.fmt.bytesToHex(sha512, .lower));
    try std.testing.expectError(error.InvalidIterations, derive("password", "salt", 0, .sha256));
}

test "password wire bytes require exact UTF-8 before PBKDF2 and allow empty text" {
    for ([_][]const u8{ &.{0xff}, &.{ 0xc0, 0x80 }, &.{ 0xed, 0xa0, 0x80 }, &.{ 0xe2, 0x82 } }) |password| {
        try std.testing.expectError(error.InvalidPasswordUtf8, validatePassword(password));
        try std.testing.expectError(error.InvalidPasswordUtf8, derive(password, "0123456789abcdef", 1, .sha256));
    }
    try validatePassword("");
    try validatePassword("é😀");
    var key = try derive("", "0123456789abcdef", 1, .sha256);
    defer erase(&key);
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

test "manual crypto entropy has exact blocks and preserves leftovers across requests" {
    var together: [48]u8 = undefined;
    var split: [48]u8 = undefined;
    specRandom(&together, 0);
    specRandom(split[0..16], 0);
    specRandom(split[16..28], 16);
    specRandom(split[28..], 28);
    try std.testing.expectEqualSlices(u8, &together, &split);
    try std.testing.expectEqualStrings("5e60aa77b3e5d4ecbad38612bdff46d7abf177ccadba293d2fd0b2f17d7a5dd1832ba8682ab91c2e6476fc488fc7d89c", &std.fmt.bytesToHex(together, .lower));
}
