const std = @import("std");
const r4os = @import("r4os");

const raster = r4os.raster;

pub const Error = error{
    InvalidDimensions,
    TooLarge,
    BufferTooSmall,
};

pub const WriteBpp = enum(u16) {
    bpp24 = 24,
    bpp32 = 32,
};

const file_header_size: usize = 14;
const dib_header_size: usize = 40;
const encoded_header_size: usize = file_header_size + dib_header_size;
const compression_rgb: u32 = 0;

pub fn encodedSize(image: raster.Image, bpp: WriteBpp) Error!usize {
    _ = try validateImage(image);
    const stride = try rowStride(image.width, @intFromEnum(bpp));
    return encoded_header_size + try imageBytes(stride, image.height);
}

pub fn encode(image: raster.Image, out: []u8, bpp: WriteBpp) Error!usize {
    _ = try validateImage(image);
    const raw_bpp: u16 = @intFromEnum(bpp);
    const stride = try rowStride(image.width, raw_bpp);
    const pixel_bytes = try imageBytes(stride, image.height);
    const total = encoded_header_size + pixel_bytes;
    if (out.len < total) return error.BufferTooSmall;

    @memset(out[0..total], 0);
    writeU16(out, 0, 0x4D42);
    writeU32(out, 2, @intCast(total));
    writeU32(out, 10, encoded_header_size);
    writeU32(out, 14, dib_header_size);
    writeI32(out, 18, @intCast(image.width));
    writeI32(out, 22, @intCast(image.height));
    writeU16(out, 26, 1);
    writeU16(out, 28, raw_bpp);
    writeU32(out, 30, compression_rgb);
    writeU32(out, 34, @intCast(pixel_bytes));

    const pixel_step = bytesPerPixel(raw_bpp);
    var file_y: u32 = 0;
    while (file_y < image.height) : (file_y += 1) {
        const source_y = image.height - 1 - file_y;
        const row_start = encoded_header_size + @as(usize, file_y) * stride;
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const color = image.storage[@as(usize, source_y) * @as(usize, image.width) + @as(usize, x)];
            const pixel_start = row_start + @as(usize, x) * pixel_step;
            out[pixel_start + 0] = raster.blue(color);
            out[pixel_start + 1] = raster.green(color);
            out[pixel_start + 2] = raster.red(color);
            if (raw_bpp == 32) out[pixel_start + 3] = 0xFF;
        }
    }

    return total;
}

fn validateImage(image: raster.Image) Error!usize {
    const needed = raster.requiredPixels(image.width, image.height) catch |err| return switch (err) {
        error.InvalidSize => error.InvalidDimensions,
        error.TooLarge => error.TooLarge,
    };
    if (needed > image.storage.len) return error.InvalidDimensions;
    return needed;
}

fn rowStride(width: u32, bpp: u16) Error!usize {
    const bits = @as(u64, width) * @as(u64, bpp);
    const bytes = ((bits + 31) / 32) * 4;
    if (bytes > std.math.maxInt(usize)) return error.TooLarge;
    return @intCast(bytes);
}

fn imageBytes(stride: usize, height: u32) Error!usize {
    const bytes = @as(u64, stride) * @as(u64, height);
    if (bytes > std.math.maxInt(usize)) return error.TooLarge;
    return @intCast(bytes);
}

fn bytesPerPixel(bpp: u16) usize {
    return @as(usize, bpp) / 8;
}

fn writeU16(out: []u8, offset: usize, value: u16) void {
    out[offset + 0] = @intCast(value & 0xFF);
    out[offset + 1] = @intCast((value >> 8) & 0xFF);
}

fn writeU32(out: []u8, offset: usize, value: u32) void {
    out[offset + 0] = @intCast(value & 0xFF);
    out[offset + 1] = @intCast((value >> 8) & 0xFF);
    out[offset + 2] = @intCast((value >> 16) & 0xFF);
    out[offset + 3] = @intCast((value >> 24) & 0xFF);
}

fn writeI32(out: []u8, offset: usize, value: i32) void {
    writeU32(out, offset, @bitCast(value));
}

test "Paint writes deterministic 24-bit BMP data" {
    var pixels = [_]u32{ raster.rgb(1, 2, 3), raster.rgb(4, 5, 6) };
    const image = raster.Image{ .width = 2, .height = 1, .storage = pixels[0..] };
    var bytes: [62]u8 = .{0} ** 62;
    const length = try encode(image, bytes[0..], .bpp24);
    try std.testing.expectEqual(@as(usize, 62), length);
    try std.testing.expectEqualSlices(u8, "BM", bytes[0..2]);
    try std.testing.expectEqual(@as(u8, 3), bytes[54]);
    try std.testing.expectEqual(@as(u8, 2), bytes[55]);
    try std.testing.expectEqual(@as(u8, 1), bytes[56]);
}
