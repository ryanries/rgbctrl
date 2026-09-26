const std = @import("std");
const sdk = @import("sdk");

const first_address: u8 = 0x18;
const last_address: u8 = 0x1F;
pub const address_count = last_address - first_address + 1;
pub const led_count = 10;
pub const frame_length = 32;
pub const info_length = 32;
pub const direct_command: u8 = 0x31;
pub const direct_payload_count: u8 = 0x20;

pub const GuardState = enum {
    unknown,
    stage1,
    verified,
    rejected,
    lost,
};

const GuardOperation = enum {
    read_stage1,
    read_info,
    write_frame,
};

const Stage1Bytes = struct {
    register_43: u8,
    register_44: u8,
};

pub const Observation = union(enum) {
    stage1: Stage1Bytes,
    info: InfoRead,
    transaction_failed,
    frame_write_failed,
    recover,
};

const GuardTransition = struct {
    state: GuardState,
    operation: ?GuardOperation,
};

const InfoRead = struct {
    block: [info_length]u8,
    crc: u8,
};

const Info = struct {
    vendor_id: u16,
    product_id: u16,
    protocol_version: u8,
    firmware_major: u8,
    firmware_minor: u8,
    firmware_build: u16,
};

const InfoError = error{
    CrcMismatch,
    UnsupportedVendor,
    UnsupportedProduct,
    UnsupportedProtocol,
};

fn operationFor(state: GuardState) ?GuardOperation {
    return switch (state) {
        .unknown => .read_stage1,
        .stage1 => .read_info,
        .verified => .write_frame,
        .rejected, .lost => null,
    };
}

pub fn applyObservation(state: GuardState, observation: Observation) GuardTransition {
    const next_state: GuardState = switch (observation) {
        .recover => switch (state) {
            .rejected, .lost => .unknown,
            else => state,
        },
        .transaction_failed => switch (state) {
            .verified => .lost,
            else => .rejected,
        },
        .frame_write_failed => .lost,
        .stage1 => |bytes| if (state == .unknown and isStage1(bytes.register_43, bytes.register_44)) .stage1 else .rejected,
        .info => |read| if (state == .stage1 and parseInfo(read.block, read.crc) != null) .verified else .rejected,
    };
    return .{ .state = next_state, .operation = operationFor(next_state) };
}

pub fn parseInfo(block: [info_length]u8, expected_crc: u8) ?Info {
    return parseInfoStrict(block, expected_crc) catch null;
}

fn parseInfoStrict(block: [info_length]u8, expected_crc: u8) InfoError!Info {
    if (crc8(&block) != expected_crc) return error.CrcMismatch;
    const vendor_id = std.mem.readInt(u16, block[0..2], .little);
    if (vendor_id != 0x1B1C) return error.UnsupportedVendor;
    const product_id = std.mem.readInt(u16, block[2..4], .little);
    if (!isSupportedProduct(product_id)) return error.UnsupportedProduct;
    const protocol_version = block[28];
    if (protocol_version < 4) return error.UnsupportedProtocol;
    return .{
        .vendor_id = vendor_id,
        .product_id = product_id,
        .protocol_version = protocol_version,
        .firmware_major = block[9],
        .firmware_minor = block[8],
        .firmware_build = std.mem.readInt(u16, block[10..12], .little),
    };
}

pub fn buildFrame(colors: *const [led_count]sdk.abi.Rgb) [frame_length]u8 {
    var frame: [frame_length]u8 = undefined;
    frame[0] = led_count;
    for (colors, 0..) |color, index| {
        const offset = 1 + index * 3;
        frame[offset] = color.r;
        frame[offset + 1] = color.g;
        frame[offset + 2] = color.b;
    }
    frame[31] = crc8(frame[0..31]);
    return frame;
}

fn crc8(bytes: []const u8) u8 {
    var crc: u8 = 0;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            if ((crc & 0x80) != 0) {
                crc = (crc << 1) ^ 0x07;
            } else {
                crc <<= 1;
            }
        }
    }
    return crc;
}

pub fn isAllowedAddress(address: u8) bool {
    return address >= first_address and address <= last_address;
}

fn addressIndex(address: u8) ?usize {
    if (!isAllowedAddress(address)) return null;
    return address - first_address;
}

pub fn addressAt(index: usize) u8 {
    return first_address + @as(u8, @intCast(index));
}

fn isStage1(register_43: u8, register_44: u8) bool {
    return switch (register_43) {
        0x1A, 0x1B, 0x1C => switch (register_44) {
            0x01, 0x03, 0x04 => true,
            else => false,
        },
        else => false,
    };
}

fn isSupportedProduct(product_id: u16) bool {
    return switch (product_id) {
        0x0700, 0x0701, 0x0900, 0x0901, 0x0910, 0x0911 => true,
        else => false,
    };
}

fn validInfoBlock(product_id: u16, protocol_version: u8) InfoRead {
    var block: [info_length]u8 = [_]u8{0} ** info_length;
    std.mem.writeInt(u16, block[0..2], 0x1B1C, .little);
    std.mem.writeInt(u16, block[2..4], product_id, .little);
    block[8] = 2;
    block[9] = 1;
    std.mem.writeInt(u16, block[10..12], 9, .little);
    block[28] = protocol_version;
    return .{ .block = block, .crc = crc8(&block) };
}

test "crc8 matches the published SMBus check value" {
    try std.testing.expectEqual(@as(u8, 0xF4), crc8("123456789"));
}

test "frame builder emits the all red DDR5 direct frame vector" {
    const colors = [_]sdk.abi.Rgb{.{ .r = 0xFF, .g = 0, .b = 0 }} ** led_count;
    const frame = buildFrame(&colors);
    try std.testing.expectEqual(@as(u8, 0x0A), frame[0]);
    for (0..led_count) |index| {
        const offset = 1 + index * 3;
        try std.testing.expectEqual(@as(u8, 0xFF), frame[offset]);
        try std.testing.expectEqual(@as(u8, 0), frame[offset + 1]);
        try std.testing.expectEqual(@as(u8, 0), frame[offset + 2]);
    }
    try std.testing.expectEqual(@as(u8, 0x6C), frame[31]);
}

test "frame builder emits the all off and all white CRC vectors" {
    const off_colors = [_]sdk.abi.Rgb{sdk.abi.Rgb.black} ** led_count;
    const off_frame = buildFrame(&off_colors);
    try std.testing.expectEqual(@as(u8, 0xBB), off_frame[31]);
    const white_colors = [_]sdk.abi.Rgb{.{ .r = 0xFF, .g = 0xFF, .b = 0xFF }} ** led_count;
    const white_frame = buildFrame(&white_colors);
    try std.testing.expectEqual(@as(u8, 0x60), white_frame[31]);
}

test "info parser accepts every supported product when the CRC and protocol match" {
    for ([_]u16{ 0x0700, 0x0701, 0x0900, 0x0901, 0x0910, 0x0911 }) |product_id| {
        const read = validInfoBlock(product_id, 4);
        const info = try parseInfoStrict(read.block, read.crc);
        try std.testing.expectEqual(@as(u16, 0x1B1C), info.vendor_id);
        try std.testing.expectEqual(product_id, info.product_id);
        try std.testing.expectEqual(@as(u8, 4), info.protocol_version);
        try std.testing.expectEqual(@as(u8, 1), info.firmware_major);
        try std.testing.expectEqual(@as(u8, 2), info.firmware_minor);
        try std.testing.expectEqual(@as(u16, 9), info.firmware_build);
    }
}

test "info parser rejects a mismatched CRC" {
    const read = validInfoBlock(0x0901, 4);
    try std.testing.expectError(error.CrcMismatch, parseInfoStrict(read.block, read.crc ^ 0xFF));
}

test "info parser rejects a non Corsair vendor" {
    var read = validInfoBlock(0x0901, 4);
    std.mem.writeInt(u16, read.block[0..2], 0x1234, .little);
    read.crc = crc8(&read.block);
    try std.testing.expectError(error.UnsupportedVendor, parseInfoStrict(read.block, read.crc));
}

test "info parser rejects an unsupported product" {
    var read = validInfoBlock(0x0901, 4);
    std.mem.writeInt(u16, read.block[2..4], 0x2222, .little);
    read.crc = crc8(&read.block);
    try std.testing.expectError(error.UnsupportedProduct, parseInfoStrict(read.block, read.crc));
}

test "info parser rejects protocol versions below direct mode" {
    const read = validInfoBlock(0x0901, 3);
    try std.testing.expectError(error.UnsupportedProtocol, parseInfoStrict(read.block, read.crc));
}

test "guard starts by allowing only the stage one reads" {
    const transition = applyObservation(.unknown, .recover);
    try std.testing.expectEqual(GuardState.unknown, transition.state);
    try std.testing.expectEqual(GuardOperation.read_stage1, transition.operation.?);
}

test "guard advances to info reads after valid stage one bytes" {
    const transition = applyObservation(.unknown, .{ .stage1 = .{ .register_43 = 0x1A, .register_44 = 0x04 } });
    try std.testing.expectEqual(GuardState.stage1, transition.state);
    try std.testing.expectEqual(GuardOperation.read_info, transition.operation.?);
}

test "guard rejects every invalid stage one byte class" {
    const bad_first = applyObservation(.unknown, .{ .stage1 = .{ .register_43 = 0x19, .register_44 = 0x04 } });
    try std.testing.expectEqual(GuardState.rejected, bad_first.state);
    try std.testing.expectEqual(@as(?GuardOperation, null), bad_first.operation);
    const bad_second = applyObservation(.unknown, .{ .stage1 = .{ .register_43 = 0x1B, .register_44 = 0x02 } });
    try std.testing.expectEqual(GuardState.rejected, bad_second.state);
    try std.testing.expectEqual(@as(?GuardOperation, null), bad_second.operation);
}

test "guard verifies after a supported info block" {
    const read = validInfoBlock(0x0901, 4);
    const transition = applyObservation(.stage1, .{ .info = read });
    try std.testing.expectEqual(GuardState.verified, transition.state);
    try std.testing.expectEqual(GuardOperation.write_frame, transition.operation.?);
}

test "guard rejects every invalid info class" {
    var bad_crc = validInfoBlock(0x0901, 4);
    bad_crc.crc ^= 1;
    try std.testing.expectEqual(GuardState.rejected, applyObservation(.stage1, .{ .info = bad_crc }).state);
    var bad_vendor = validInfoBlock(0x0901, 4);
    std.mem.writeInt(u16, bad_vendor.block[0..2], 0x1111, .little);
    bad_vendor.crc = crc8(&bad_vendor.block);
    try std.testing.expectEqual(GuardState.rejected, applyObservation(.stage1, .{ .info = bad_vendor }).state);
    var bad_product = validInfoBlock(0x0901, 4);
    std.mem.writeInt(u16, bad_product.block[2..4], 0x1111, .little);
    bad_product.crc = crc8(&bad_product.block);
    try std.testing.expectEqual(GuardState.rejected, applyObservation(.stage1, .{ .info = bad_product }).state);
    const bad_protocol = validInfoBlock(0x0901, 1);
    try std.testing.expectEqual(GuardState.rejected, applyObservation(.stage1, .{ .info = bad_protocol }).state);
}

test "guard rejects identification failures and marks verified write failures lost" {
    try std.testing.expectEqual(GuardState.rejected, applyObservation(.unknown, .transaction_failed).state);
    try std.testing.expectEqual(GuardState.rejected, applyObservation(.stage1, .transaction_failed).state);
    try std.testing.expectEqual(GuardState.lost, applyObservation(.verified, .transaction_failed).state);
    try std.testing.expectEqual(GuardState.lost, applyObservation(.verified, .frame_write_failed).state);
}

test "guard recovers only rejected and lost addresses for another probe" {
    try std.testing.expectEqual(GuardState.unknown, applyObservation(.rejected, .recover).state);
    try std.testing.expectEqual(GuardState.unknown, applyObservation(.lost, .recover).state);
    try std.testing.expectEqual(GuardState.verified, applyObservation(.verified, .recover).state);
}

test "address helpers allow only the DDR5 RGB range" {
    try std.testing.expect(!isAllowedAddress(0x17));
    try std.testing.expect(isAllowedAddress(0x18));
    try std.testing.expect(isAllowedAddress(0x1F));
    try std.testing.expect(!isAllowedAddress(0x20));
    try std.testing.expectEqual(@as(usize, 0), addressIndex(0x18).?);
    try std.testing.expectEqual(@as(u8, 0x1F), addressAt(7));
}
