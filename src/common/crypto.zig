//! 数据源密码加解密 (V1 简化方案)
//!
//! 算法: XOR + SHA256 派生 keystream (RC4-like 但更稳)
//! 存储格式: hex(iv(8)) + ':' + base64(ciphertext)
//!
//! 注: V1 简易方案, 用于"不让明文落盘"的基本诉求. 后续可换 KMS/secret manager.

const std = @import("std");

const SALT: []const u8 = "zetl-v1-salt-2026";
const KEY_BYTES: usize = 32;

/// 用 SHA256(秘钥+salt) 派生 32 字节主密钥 (运行时计算, 避免 comptime 分支超限)
fn deriveKey() [KEY_BYTES]u8 {
    const seed = "zetl-master-key-do-not-change";
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(seed);
    hasher.update(SALT);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

var cached_key: ?[KEY_BYTES]u8 = null;
fn getKey() [KEY_BYTES]u8 {
    if (cached_key) |k| return k;
    const k = deriveKey();
    cached_key = k;
    return k;
}

/// 用 SHA256(key||iv) 派生一个 keystream 块 (32 字节)
fn keystreamBlock(key: *const [32]u8, iv: *const [16]u8, counter: u64) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(key);
    hasher.update(iv);
    var ctr_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &ctr_bytes, counter, .little);
    hasher.update(&ctr_bytes);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// 加密 (返回 16字节iv-hex + ':' + base64密文)
pub fn encrypt(allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
    const key = getKey();
    var iv: [16]u8 = undefined;
    osRandomBytes(&iv);

    const ct_len = plaintext.len;
    const ct = try allocator.alloc(u8, ct_len);
    defer allocator.free(ct);

    var offset: usize = 0;
    var counter: u64 = 0;
    while (offset < ct_len) {
        const block = keystreamBlock(&key, &iv, counter);
        const take = @min(32, ct_len - offset);
        for (0..take) |i| {
            ct[offset + i] = plaintext[offset + i] ^ block[i];
        }
        offset += take;
        counter += 1;
    }

    const enc_iv = std.fmt.bytesToHex(&iv, .lower);
    // base64 encode: 先算 dest 大小, 再 alloc + encode
    const enc_size = std.base64.url_safe_no_pad.Encoder.calcSize(ct.len);
    const enc_buf = try allocator.alloc(u8, enc_size);
    const enc_ct = std.base64.url_safe_no_pad.Encoder.encode(enc_buf, ct);
    defer allocator.free(enc_ct);

    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ enc_iv, enc_ct });
}

/// 解密
pub fn decrypt(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const key = getKey();
    const colon = std.mem.indexOfScalar(u8, payload, ':') orelse return error.BadCipherFormat;
    const hex_iv = payload[0..colon];
    const b64_ct = payload[colon + 1 ..];

    if (hex_iv.len != 32) return error.BadCipherIvLen;
    var iv: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&iv, hex_iv);

    // 解码 base64 - 用 url_safe_no_pad 解码
    const max_ct_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(b64_ct) catch return error.BadCipherB64;
    const ct = try allocator.alloc(u8, max_ct_len);
    defer allocator.free(ct);
    try std.base64.url_safe_no_pad.Decoder.decode(ct, b64_ct);

    const out = try allocator.alloc(u8, ct.len);
    var offset: usize = 0;
    var counter: u64 = 0;
    while (offset < ct.len) {
        const block = keystreamBlock(&key, &iv, counter);
        const take = @min(32, ct.len - offset);
        for (0..take) |i| {
            out[offset + i] = ct[offset + i] ^ block[i];
        }
        offset += take;
        counter += 1;
    }
    return out;
}

test "crypto roundtrip" {
    const a = std.testing.allocator;
    const plain = "my-secret-password-123";
    const enc = try encrypt(a, plain);
    defer a.free(enc);
    const dec = try decrypt(a, enc);
    defer a.free(dec);
    try std.testing.expectEqualStrings(plain, dec);
}

test "crypto roundtrip chinese" {
    const a = std.testing.allocator;
    const plain = "数据库密码-mall#001";
    const enc = try encrypt(a, plain);
    defer a.free(enc);
    const dec = try decrypt(a, enc);
    defer a.free(dec);
    try std.testing.expectEqualStrings(plain, dec);
}

/// 跨平台 OS 随机字节 (V1: macOS 走 arc4random_buf, Linux 走 getrandom, 其它 fallback 时间戳)
fn osRandomBytes(buf: []u8) void {
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            var offset: usize = 0;
            while (offset < buf.len) {
                const chunk_len = @min(buf.len - offset, 256);
                const rc = std.c.getrandom(buf.ptr + offset, chunk_len, 0);
                if (rc < 0) @panic("getrandom failed");
                offset += @intCast(rc);
            }
        },
        else => {
            // Fallback: 弱随机 (V1 测试用)
            var ts: u64 = @bitCast(@as(i128, std.time.nanoTimestamp()));
            for (buf, 0..) |*b, i| {
                ts = ts *% 6364136223846793005 +% 1442695040888963407;
                b.* = @truncate(ts >> 32);
                ts +%= i + 1;
            }
        },
    }
}
