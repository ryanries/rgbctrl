export fn memcpy(noalias dest: ?[*]u8, noalias src: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    var index: usize = 0;
    while (index < len) : (index += 1) dest.?[index] = src.?[index];
    return dest;
}

export fn memmove(dest: ?[*]u8, src: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len == 0) return dest;
    const dest_address = @intFromPtr(dest.?);
    const src_address = @intFromPtr(src.?);
    if (dest_address <= src_address or dest_address >= src_address + len) {
        var index: usize = 0;
        while (index < len) : (index += 1) dest.?[index] = src.?[index];
    } else {
        var index: usize = len;
        while (index > 0) {
            index -= 1;
            dest.?[index] = src.?[index];
        }
    }
    return dest;
}

export fn memset(dest: ?[*]u8, value: u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    var index: usize = 0;
    while (index < len) : (index += 1) dest.?[index] = value;
    return dest;
}

export fn memcmp(left: ?[*]const u8, right: ?[*]const u8, len: usize) callconv(.c) c_int {
    @setRuntimeSafety(false);
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const a = left.?[index];
        const b = right.?[index];
        if (a != b) return @as(c_int, a) - @as(c_int, b);
    }
    return 0;
}

export fn strlen(text: ?[*]const u8) callconv(.c) usize {
    @setRuntimeSafety(false);
    var length: usize = 0;
    while (text.?[length] != 0) length += 1;
    return length;
}

export fn wcslen(text: ?[*]const u16) callconv(.c) usize {
    @setRuntimeSafety(false);
    var length: usize = 0;
    while (text.?[length] != 0) length += 1;
    return length;
}

export fn ___chkstk_ms() callconv(.naked) void {
    asm volatile (
        \\        pushq  %%rcx
        \\        pushq  %%rax
        \\        cmpq   $0x1000, %%rax
        \\        leaq   24(%%rsp), %%rcx
        \\        jb     2f
        \\1:
        \\        subq   $0x1000, %%rcx
        \\        orq    $0, (%%rcx)
        \\        subq   $0x1000, %%rax
        \\        cmpq   $0x1000, %%rax
        \\        ja     1b
        \\2:
        \\        subq   %%rax, %%rcx
        \\        orq    $0, (%%rcx)
        \\        popq   %%rax
        \\        popq   %%rcx
        \\        retq
    );
}
