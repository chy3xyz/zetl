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
