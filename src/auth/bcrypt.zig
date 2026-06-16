//! 密码哈希 (SHA256 + random salt) - V2.2
//! 存储格式: hex(salt) + ':' + hex(SHA256(salt + password))

const std = @import("std");

pub fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    var salt: [16]u8 = undefined;
    std.c.arc4random_buf(&salt, salt.len);
    const salt_hex = std.fmt.bytesToHex(&salt, .lower);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&salt);
    hasher.update(password);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(&digest, .lower);

    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ salt_hex, digest_hex });
}

pub fn verifyPassword(password: []const u8, hash: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, hash, ':') orelse return false;
    const salt_hex = hash[0..colon];
    if (salt_hex.len != 32) return false;

    var salt: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&salt, salt_hex) catch return false;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&salt);
    hasher.update(password);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(&digest, .lower);

    const expected = hash[colon + 1 ..];
    return std.mem.eql(u8, &digest_hex, expected);
}

test "hashPassword: format is salt:digest" {
    const a = std.testing.allocator;
    const h = try hashPassword(a, "hello-world");
    defer a.free(h);
    // 32-char salt hex + ':' + 64-char digest hex = 97 chars
    try std.testing.expectEqual(@as(usize, 97), h.len);
    const colon_idx = std.mem.indexOfScalar(u8, h, ':').?;
    try std.testing.expectEqual(@as(usize, 32), colon_idx);
    // Salt must be valid hex
    for (h[0..32]) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    // Digest part must be valid hex
    for (h[33..]) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "hashPassword: each call produces a different salt" {
    const a = std.testing.allocator;
    const h1 = try hashPassword(a, "same-password");
    defer a.free(h1);
    const h2 = try hashPassword(a, "same-password");
    defer a.free(h2);
    // Different salts → different hashes
    try std.testing.expect(!std.mem.eql(u8, h1, h2));
}

test "verifyPassword: correct password returns true" {
    const a = std.testing.allocator;
    const plain = "MyStr0ng!Pass";
    const h = try hashPassword(a, plain);
    defer a.free(h);
    try std.testing.expect(verifyPassword(plain, h));
}

test "verifyPassword: wrong password returns false" {
    const a = std.testing.allocator;
    const h = try hashPassword(a, "right-password");
    defer a.free(h);
    try std.testing.expect(!verifyPassword("wrong-password", h));
}

test "verifyPassword: malformed hash returns false" {
    // No colon
    try std.testing.expect(!verifyPassword("anything", "no-colon-here"));
    // Wrong salt length
    try std.testing.expect(!verifyPassword("anything", "ab:00"));
    // Garbage salt hex
    try std.testing.expect(!verifyPassword("anything", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz:00"));
    // Empty
    try std.testing.expect(!verifyPassword("anything", ""));
}

test "verifyPassword: chinese password roundtrip" {
    const a = std.testing.allocator;
    const plain = "数据库密码-mall#001";
    const h = try hashPassword(a, plain);
    defer a.free(h);
    try std.testing.expect(verifyPassword(plain, h));
    try std.testing.expect(!verifyPassword("not-it", h));
}
