const std = @import("std");
const Opcode = @import("types.zig").Opcode;
pub const Frame = @import("types.zig").Frame;

pub fn parseFrame(data: []u8) !Frame {
    if (data.len < 2) return error.IncompleteFrame;

    const first_byte = data[0];
    const second_byte = data[1];

    const fin = (first_byte & 0x80) != 0;
    const opcode = Opcode.fromByte(first_byte) orelse return error.UnknownOpcode;
    const mask = (second_byte & 0x80) != 0;
    var payload_len: u64 = @intCast(second_byte & 0x7F);

    var offset: usize = 2;

    if (payload_len == 126) {
        if (data.len < 4) return error.IncompleteFrame;
        payload_len = std.mem.readInt(u16, data[2..4], .big);
        offset = 4;
    } else if (payload_len == 127) {
        if (data.len < 10) return error.IncompleteFrame;
        payload_len = std.mem.readInt(u64, data[2..10], .big);
        if (payload_len & 0x8000_0000_0000_0000 != 0) return error.InvalidFrame;
        offset = 10;
    }

    var mask_key: [4]u8 = undefined;
    if (mask) {
        if (data.len < offset + 4) return error.IncompleteFrame;
        @memcpy(&mask_key, data[offset..][0..4]);
        offset += 4;
    }

    if (data.len < offset + payload_len) return error.IncompleteFrame;
    const payload = data[offset..][0..@as(usize, @intCast(payload_len))];

    if (mask) {
        maskPayload(payload, mask_key);
    }

    return Frame{ .opcode = opcode, .fin = fin, .payload = payload };
}

pub fn frameSize(payload_len: usize) usize {
    var hdr: usize = 2;
    if (payload_len > 125) {
        if (payload_len > 0xFFFF) {
            hdr += 8;
        } else {
            hdr += 2;
        }
    }
    return hdr + payload_len;
}

pub fn writeFrame(buf: []u8, frame: Frame) !usize {
    const total = frameSize(frame.payload.len);
    if (buf.len < total) return error.BufferTooSmall;

    var first_byte: u8 = 0;
    if (frame.fin) first_byte |= 0x80;
    first_byte |= @as(u8, @intFromEnum(frame.opcode));
    buf[0] = first_byte;

    var offset: usize = 1;

    if (frame.payload.len <= 125) {
        buf[1] = @as(u8, @intCast(frame.payload.len));
        offset = 2;
    } else if (frame.payload.len <= 0xFFFF) {
        buf[1] = 126;
        std.mem.writeInt(u16, buf[2..4], @as(u16, @intCast(frame.payload.len)), .big);
        offset = 4;
    } else {
        buf[1] = 127;
        std.mem.writeInt(u64, buf[2..10], @as(u64, @intCast(frame.payload.len)), .big);
        offset = 10;
    }

    @memcpy(buf[offset..][0..frame.payload.len], frame.payload);
    return total;
}

/// SIMD 加速 WebSocket 掩码计算。
/// 将 4 字节 mask_key 复制为 16 字节向量，16 字节/轮 XOR。
fn maskPayload(payload: []u8, mask_key: [4]u8) void {
    const Vec = @Vector(16, u8);
    const mask_vec: Vec = [_]u8{
        mask_key[0], mask_key[1], mask_key[2], mask_key[3],
        mask_key[0], mask_key[1], mask_key[2], mask_key[3],
        mask_key[0], mask_key[1], mask_key[2], mask_key[3],
        mask_key[0], mask_key[1], mask_key[2], mask_key[3],
    };

    var i: usize = 0;
    const chunk_count = payload.len / 16;
    if (chunk_count > 0 and @intFromPtr(&payload[0]) & 15 == 0) {
        // Aligned fast path: SIMD XOR 16 bytes at a time
        for (0..chunk_count) |_| {
            const chunk: *Vec = @ptrCast(@alignCast(&payload[i]));
            chunk.* ^= mask_vec;
            i += 16;
        }
    } else {
        // Unaligned slow path: byte-by-byte for safety
        const end = chunk_count * 16;
        while (i < end) : (i += 1) {
            payload[i] ^= mask_key[i & 3];
        }
    }
    // Tail: remaining < 16 bytes
    while (i < payload.len) : (i += 1) {
        payload[i] ^= mask_key[i & 3];
    }
}
