const std = @import("std");

const heap_handle_type = *anyopaque;
const heap_realloc_in_place_only: u32 = 0x10;

extern "kernel32" fn GetProcessHeap() callconv(.winapi) ?heap_handle_type;
extern "kernel32" fn HeapAlloc(heap: heap_handle_type, flags: u32, bytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn HeapReAlloc(heap: heap_handle_type, flags: u32, memory: *anyopaque, bytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn HeapFree(heap: heap_handle_type, flags: u32, memory: *anyopaque) callconv(.winapi) i32;

const max_supported_alignment = 16;

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

fn processHeap() heap_handle_type {
    return GetProcessHeap().?;
}

fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
    _ = context;
    _ = return_address;
    if (alignment.toByteUnits() > max_supported_alignment) return null;
    const memory = HeapAlloc(processHeap(), 0, @max(len, 1)) orelse return null;
    return @ptrCast(memory);
}

fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
    _ = context;
    _ = alignment;
    _ = return_address;
    if (new_len <= memory.len) return true;
    return HeapReAlloc(processHeap(), heap_realloc_in_place_only, memory.ptr, new_len) != null;
}

fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
    _ = context;
    _ = return_address;
    if (alignment.toByteUnits() > max_supported_alignment) return null;
    const moved = HeapReAlloc(processHeap(), 0, memory.ptr, @max(new_len, 1)) orelse return null;
    return @ptrCast(moved);
}

fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
    _ = context;
    _ = alignment;
    _ = return_address;
    _ = HeapFree(processHeap(), 0, memory.ptr);
}

test "the process heap allocator allocates, grows and frees" {
    const buffer = try allocator.alloc(u8, 100);
    @memset(buffer, 7);
    const grown = try allocator.realloc(buffer, 5000);
    try std.testing.expectEqual(@as(u8, 7), grown[99]);
    allocator.free(grown);
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(allocator);
    for (0..1000) |index| try list.append(allocator, @intCast(index));
    try std.testing.expectEqual(@as(u32, 999), list.items[999]);
}
