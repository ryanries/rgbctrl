const std = @import("std");
const json = @import("../config/json.zig");

// Edits a configuration file (JSON with comments) in place: only the text of a changed member is
// rewritten, so comments, formatting and every other key stay as they were. Each edit is checked
// by reading the result with rgbctrl's own parser before it is kept.

pub const Error = error{ OutOfMemory, Syntax, NotAnObject, EditFailed };

const max_depth = 64;
const max_duplicates = 64;

const Kind = enum { object, array, string, number, literal };

const Value = struct {
    kind: Kind,
    start: usize,
    end: usize,
    members: []const Member = &.{},
};

const Member = struct {
    key: []const u8,
    key_start: usize,
    value: *const Value,
    comma: ?usize,
};

// Records where every value, member and comma is, for text the parser has already accepted.
const Scanner = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,
    depth: u32 = 0,

    fn document(self: *Scanner) Error!?*const Value {
        if (std.mem.startsWith(u8, self.source, "\xEF\xBB\xBF")) self.index = 3;
        self.skipTrivia();
        if (self.index == self.source.len) return null;
        const root = try self.value();
        self.skipTrivia();
        if (self.index != self.source.len or root.kind != .object) return error.Syntax;
        return root;
    }

    fn peek(self: *const Scanner) u8 {
        return if (self.index < self.source.len) self.source[self.index] else 0;
    }

    fn skipTrivia(self: *Scanner) void {
        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                ' ', '\t', '\r', '\n' => self.index += 1,
                '/' => {
                    if (self.index + 1 >= self.source.len) return;
                    const next = self.source[self.index + 1];
                    if (next == '/') {
                        while (self.index < self.source.len and self.source[self.index] != '\n') self.index += 1;
                    } else if (next == '*') {
                        const close = std.mem.indexOfPos(u8, self.source, self.index + 2, "*/") orelse {
                            self.index = self.source.len;
                            return;
                        };
                        self.index = close + 2;
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn value(self: *Scanner) Error!*const Value {
        const start = self.index;
        switch (self.peek()) {
            '{' => return self.object(),
            '[' => return self.array(),
            '"' => {
                _ = try self.string();
                return self.leaf(.string, start);
            },
            't', 'f', 'n' => {
                inline for (.{ "true", "false", "null" }) |word| {
                    if (std.mem.startsWith(u8, self.source[start..], word)) {
                        self.index += word.len;
                        return self.leaf(.literal, start);
                    }
                }
                return error.Syntax;
            },
            '-', '0'...'9' => {
                while (self.index < self.source.len) : (self.index += 1) {
                    switch (self.source[self.index]) {
                        '0'...'9', '-', '+', '.', 'e', 'E' => {},
                        else => break,
                    }
                }
                return self.leaf(.number, start);
            },
            else => return error.Syntax,
        }
    }

    fn leaf(self: *Scanner, kind: Kind, start: usize) Error!*const Value {
        const node = try self.allocator.create(Value);
        node.* = .{ .kind = kind, .start = start, .end = self.index };
        return node;
    }

    fn enter(self: *Scanner) Error!void {
        self.depth += 1;
        if (self.depth > max_depth) return error.Syntax;
    }

    fn object(self: *Scanner) Error!*const Value {
        const start = self.index;
        try self.enter();
        self.index += 1;
        var members: std.ArrayList(Member) = .empty;
        while (true) {
            self.skipTrivia();
            if (self.peek() == '}') {
                self.index += 1;
                break;
            }
            if (self.peek() != '"') return error.Syntax;
            const key_start = self.index;
            const key = try self.string();
            self.skipTrivia();
            if (self.peek() != ':') return error.Syntax;
            self.index += 1;
            self.skipTrivia();
            const member_value = try self.value();
            self.skipTrivia();
            switch (self.peek()) {
                ',' => {
                    try members.append(self.allocator, .{ .key = key, .key_start = key_start, .value = member_value, .comma = self.index });
                    self.index += 1;
                },
                '}' => {
                    try members.append(self.allocator, .{ .key = key, .key_start = key_start, .value = member_value, .comma = null });
                    self.index += 1;
                    break;
                },
                else => return error.Syntax,
            }
        }
        self.depth -= 1;
        const node = try self.allocator.create(Value);
        node.* = .{ .kind = .object, .start = start, .end = self.index, .members = members.items };
        return node;
    }

    fn array(self: *Scanner) Error!*const Value {
        const start = self.index;
        try self.enter();
        self.index += 1;
        while (true) {
            self.skipTrivia();
            if (self.peek() == ']') {
                self.index += 1;
                break;
            }
            _ = try self.value();
            self.skipTrivia();
            const separator = self.peek();
            if (separator != ',' and separator != ']') return error.Syntax;
            self.index += 1;
            if (separator == ']') break;
        }
        self.depth -= 1;
        return self.leaf(.array, start);
    }

    /// The decoded text of the string that starts at index; index ends after its closing quote.
    fn string(self: *Scanner) Error![]const u8 {
        self.index += 1;
        const content_start = self.index;
        var escaped = false;
        while (true) {
            if (self.index >= self.source.len) return error.Syntax;
            const char = self.source[self.index];
            if (char == '"') break;
            if (char == '\\') {
                escaped = true;
                self.index += 2;
            } else {
                self.index += 1;
            }
        }
        const raw = self.source[content_start..self.index];
        self.index += 1;
        if (!escaped) return raw;
        return decodeEscapes(self.allocator, raw);
    }
};

fn decodeEscapes(allocator: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < raw.len) {
        const char = raw[index];
        if (char != '\\') {
            try out.append(allocator, char);
            index += 1;
            continue;
        }
        if (index + 1 >= raw.len) return error.Syntax;
        const escape = raw[index + 1];
        index += 2;
        const simple: ?u8 = switch (escape) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 0x08,
            'f' => 0x0C,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => null,
            else => return error.Syntax,
        };
        if (simple) |byte| {
            try out.append(allocator, byte);
            continue;
        }
        var code_point = try hex4(raw, index);
        index += 4;
        if (code_point >= 0xD800 and code_point <= 0xDBFF) {
            if (index + 6 > raw.len or raw[index] != '\\' or raw[index + 1] != 'u') return error.Syntax;
            const low = try hex4(raw, index + 2);
            index += 6;
            if (low < 0xDC00 or low > 0xDFFF) return error.Syntax;
            code_point = 0x10000 + ((code_point - 0xD800) << 10) + (low - 0xDC00);
        }
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code_point, &buffer) catch return error.Syntax;
        try out.appendSlice(allocator, buffer[0..length]);
    }
    return out.items;
}

fn hex4(raw: []const u8, at: usize) Error!u21 {
    if (at + 4 > raw.len) return error.Syntax;
    var result: u21 = 0;
    for (raw[at .. at + 4]) |char| result = result * 16 + (std.fmt.charToDigit(char, 16) catch return error.Syntax);
    return result;
}

// The layout of the file, so that inserted lines look like the ones around them.
const Style = struct {
    newline: []const u8,
    indent_unit: []const u8,
};

fn detectStyle(source: []const u8, root: *const Value) Style {
    var style = Style{ .newline = if (std.mem.indexOf(u8, source, "\r\n") != null) "\r\n" else "\n", .indent_unit = "  " };
    for (root.members) |member| {
        const indentation = ownLineIndentation(source, member.key_start) orelse continue;
        if (indentation.len > 0) style.indent_unit = indentation;
        break;
    }
    return style;
}

fn lineStart(source: []const u8, offset: usize) usize {
    var start = offset;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    return start;
}

/// The blanks before offset on its line, or null when other text precedes it there.
fn ownLineIndentation(source: []const u8, offset: usize) ?[]const u8 {
    const start = lineStart(source, offset);
    for (source[start..offset]) |char| {
        if (char != ' ' and char != '\t') return null;
    }
    return source[start..offset];
}

/// The leading blanks of the line that holds offset.
fn lineIndentation(source: []const u8, offset: usize) []const u8 {
    const start = lineStart(source, offset);
    var end = start;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    return source[start..end];
}

/// Where the line break after offset starts, when only blanks and comments follow offset on its
/// line (the end of the text counts as a break); null when anything else follows. A block
/// comment that starts on the line counts as part of it even when it ends on a later line, so a
/// new member goes after the comment of the member before it.
fn lineBreakAfter(source: []const u8, offset: usize) ?usize {
    var index = offset;
    while (index < source.len) {
        switch (source[index]) {
            ' ', '\t' => index += 1,
            '\r', '\n' => return index,
            '/' => {
                if (index + 1 >= source.len) return null;
                if (source[index + 1] == '/') {
                    var end = index;
                    while (end < source.len and source[end] != '\n') end += 1;
                    if (end < source.len and source[end - 1] == '\r') return end - 1;
                    return end;
                }
                if (source[index + 1] != '*') return null;
                const close = std.mem.indexOfPos(u8, source, index + 2, "*/") orelse return null;
                index = close + 2;
            },
            else => return null,
        }
    }
    return source.len;
}

/// The end of the block comments that follow offset on its line, or offset when there are none.
fn sameLineCommentsEnd(source: []const u8, offset: usize) usize {
    var index = offset;
    var end = offset;
    while (index + 1 < source.len) {
        switch (source[index]) {
            ' ', '\t' => index += 1,
            '/' => {
                if (source[index + 1] != '*') break;
                const close = std.mem.indexOfPos(u8, source, index + 2, "*/") orelse break;
                if (std.mem.indexOfScalar(u8, source[index..close], '\n') != null) break;
                index = close + 2;
                end = index;
            },
            else => break,
        }
    }
    return end;
}

fn isBlank(text: []const u8) bool {
    for (text) |char| {
        if (char != ' ' and char != '\t' and char != '\r' and char != '\n') return false;
    }
    return true;
}

fn findLastIndex(object: *const Value, key: []const u8) ?usize {
    var index = object.members.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, object.members[index].key, key)) return index;
    }
    return null;
}

fn findLast(object: *const Value, key: []const u8) ?*const Member {
    const index = findLastIndex(object, key) orelse return null;
    return &object.members[index];
}

fn findObject(root: *const Value, keys: []const []const u8) ?*const Value {
    var current = root;
    for (keys) |key| {
        const member = findLast(current, key) orelse return null;
        if (member.value.kind != .object) return null;
        current = member.value;
    }
    return current;
}

const Edit = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

/// Applies edits that are sorted by position and do not overlap.
fn applyEdits(allocator: std.mem.Allocator, source: []const u8, edits: []const Edit) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (edits) |edit| {
        if (edit.start < cursor or edit.end < edit.start or edit.end > source.len) return error.EditFailed;
        try out.appendSlice(allocator, source[cursor..edit.start]);
        try out.appendSlice(allocator, edit.text);
        cursor = edit.end;
    }
    try out.appendSlice(allocator, source[cursor..]);
    return out.items;
}

fn parseChecked(allocator: std.mem.Allocator, source: []const u8) Error!*const json.Node {
    var warnings: std.ArrayList(json.Issue) = .empty;
    return switch (try json.parse(allocator, source, &warnings)) {
        .document => |document| document,
        .failure => error.Syntax,
    };
}

fn lookup(root: *const json.Node, path: []const []const u8) ?*const json.Node {
    var current = root;
    for (path) |key| {
        if (current.kind() != .object) return null;
        current = current.get(key) orelse return null;
    }
    return current;
}

pub const Editor = struct {
    allocator: std.mem.Allocator,
    source: []const u8,

    /// Fails with error.Syntax for text that rgbctrl could not read either. The allocator should
    /// be an arena: every edit allocates a new copy of the text.
    pub fn init(allocator: std.mem.Allocator, source: []const u8) Error!Editor {
        _ = try parseChecked(allocator, source);
        return .{ .allocator = allocator, .source = source };
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.source;
    }

    /// The value at path as rgbctrl reads the current text.
    pub fn get(self: *const Editor, path: []const []const u8) Error!?*const json.Node {
        return lookup(try parseChecked(self.allocator, self.source), path);
    }

    /// Sets the member at path to value_text (one JSON value), creating the objects on the way.
    /// With duplicated keys the last one, which rgbctrl uses, is changed. On failure the text
    /// stays as it was.
    pub fn set(self: *Editor, path: []const []const u8, value_text: []const u8) Error!void {
        if (path.len == 0) return error.EditFailed;
        const expected = try parseValueText(self.allocator, value_text);
        // The edit goes to a draft, which becomes the text only once it reads back as intended.
        var draft = self.*;
        try draft.ensureRoot();
        const root = (try draft.scan()) orelse return error.EditFailed;
        const style = detectStyle(draft.source, root);
        var parent = root;
        var depth: usize = 0;
        while (depth + 1 < path.len) : (depth += 1) {
            const member = findLast(parent, path[depth]) orelse break;
            if (member.value.kind != .object) return error.NotAnObject;
            parent = member.value;
        }
        var edits: [2]Edit = undefined;
        var count: usize = 0;
        const holds_value = depth + 1 == path.len;
        if (holds_value) {
            if (findLast(parent, path[depth])) |member| {
                edits[0] = .{ .start = member.value.start, .end = member.value.end, .text = value_text };
                count = 1;
            }
        }
        if (count == 0) {
            const indentation = try draft.memberIndentation(parent, style);
            const member_value = if (holds_value) value_text else try draft.nestedValue(path[depth + 1 ..], value_text, indentation, style);
            count = try draft.insertionEdits(&edits, parent, parent == root, path[depth], member_value, style);
        }
        const edited = try applyEdits(draft.allocator, draft.source, edits[0..count]);
        const edited_root = parseChecked(draft.allocator, edited) catch return error.EditFailed;
        const actual = lookup(edited_root, path) orelse return error.EditFailed;
        if (!json.equal(actual, expected)) return error.EditFailed;
        self.source = edited;
    }

    /// Removes the member at path, every copy of it if the key is duplicated (rgbctrl would use
    /// an earlier copy otherwise). A missing member is not an error. On failure the text stays
    /// as it was.
    pub fn remove(self: *Editor, path: []const []const u8) Error!void {
        if (path.len == 0) return error.EditFailed;
        var draft = self.*;
        var removed: usize = 0;
        while (true) {
            const root = (try draft.scan()) orelse break;
            const parent = findObject(root, path[0 .. path.len - 1]) orelse break;
            const index = findLastIndex(parent, path[path.len - 1]) orelse break;
            if (removed == max_duplicates) return error.EditFailed;
            var edits: [2]Edit = undefined;
            const count = removalEdits(draft.source, parent, index, &edits);
            const edited = try applyEdits(draft.allocator, draft.source, edits[0..count]);
            _ = parseChecked(draft.allocator, edited) catch return error.EditFailed;
            draft.source = edited;
            removed += 1;
        }
        if (removed == 0) return;
        if (lookup(try parseChecked(draft.allocator, draft.source), path) != null) return error.EditFailed;
        self.source = draft.source;
    }

    /// Removes the object at path when it holds neither members nor comments.
    pub fn removeIfEmpty(self: *Editor, path: []const []const u8) Error!void {
        if (path.len == 0) return;
        const root = (try self.scan()) orelse return;
        const parent = findObject(root, path[0 .. path.len - 1]) orelse return;
        const member = findLast(parent, path[path.len - 1]) orelse return;
        if (member.value.kind != .object or member.value.members.len != 0) return;
        if (!isBlank(self.source[member.value.start + 1 .. member.value.end - 1])) return;
        try self.remove(path);
    }

    fn scan(self: *const Editor) Error!?*const Value {
        var scanner = Scanner{ .allocator = self.allocator, .source = self.source };
        return scanner.document();
    }

    // A file without a top-level object (empty, or only comments) gets one at its end.
    fn ensureRoot(self: *Editor) Error!void {
        if ((try self.scan()) != null) return;
        const newline = if (std.mem.indexOf(u8, self.source, "\r\n") != null) "\r\n" else "\n";
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.allocator, self.source);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(self.allocator, newline);
        try out.appendSlice(self.allocator, "{");
        try out.appendSlice(self.allocator, newline);
        try out.appendSlice(self.allocator, "}");
        try out.appendSlice(self.allocator, newline);
        _ = parseChecked(self.allocator, out.items) catch return error.EditFailed;
        self.source = out.items;
    }

    /// The indentation of the members of object: that of its last member on a line of its own,
    /// else one unit more than the line of its opening brace.
    fn memberIndentation(self: *const Editor, object: *const Value, style: Style) Error![]const u8 {
        var index = object.members.len;
        while (index > 0) {
            index -= 1;
            if (ownLineIndentation(self.source, object.members[index].key_start)) |indentation| return indentation;
        }
        return std.mem.concat(self.allocator, u8, &.{ lineIndentation(self.source, object.start), style.indent_unit });
    }

    /// The value of a new member whose keys down to the value are all new: objects of one member
    /// per line around a one-line object that holds the value, like the zones in the example
    /// configuration.
    fn nestedValue(self: *const Editor, keys: []const []const u8, value_text: []const u8, indentation: []const u8, style: Style) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        if (keys.len == 1) {
            try out.appendSlice(self.allocator, "{ ");
            try json.appendString(self.allocator, &out, keys[0]);
            try out.appendSlice(self.allocator, ": ");
            try out.appendSlice(self.allocator, value_text);
            try out.appendSlice(self.allocator, " }");
            return out.items;
        }
        const inner = try std.mem.concat(self.allocator, u8, &.{ indentation, style.indent_unit });
        try out.append(self.allocator, '{');
        try out.appendSlice(self.allocator, style.newline);
        try out.appendSlice(self.allocator, inner);
        try json.appendString(self.allocator, &out, keys[0]);
        try out.appendSlice(self.allocator, ": ");
        try out.appendSlice(self.allocator, try self.nestedValue(keys[1..], value_text, inner, style));
        try out.appendSlice(self.allocator, style.newline);
        try out.appendSlice(self.allocator, indentation);
        try out.append(self.allocator, '}');
        return out.items;
    }

    fn insertionEdits(self: *const Editor, edits: *[2]Edit, object: *const Value, is_root: bool, key: []const u8, member_value: []const u8, style: Style) Error!usize {
        const source = self.source;
        const allocator = self.allocator;
        var member: std.ArrayList(u8) = .empty;
        try json.appendString(allocator, &member, key);
        try member.appendSlice(allocator, ": ");
        try member.appendSlice(allocator, member_value);
        const member_text = member.items;
        const close = object.end - 1;
        const spans_lines = std.mem.indexOfScalar(u8, source[object.start..close], '\n') != null;
        if (object.members.len == 0) {
            const blank = isBlank(source[object.start + 1 .. close]);
            if (is_root or spans_lines or std.mem.indexOfScalar(u8, member_value, '\n') != null) {
                const brace_indentation = lineIndentation(source, object.start);
                const member_indentation = try std.mem.concat(allocator, u8, &.{ brace_indentation, style.indent_unit });
                if (blank) {
                    edits[0] = .{ .start = object.start + 1, .end = close, .text = try std.mem.concat(allocator, u8, &.{ style.newline, member_indentation, member_text, style.newline, brace_indentation }) };
                } else {
                    edits[0] = .{ .start = object.start + 1, .end = object.start + 1, .text = try std.mem.concat(allocator, u8, &.{ style.newline, member_indentation, member_text }) };
                }
                return 1;
            }
            if (blank) {
                edits[0] = .{ .start = object.start + 1, .end = close, .text = try std.mem.concat(allocator, u8, &.{ " ", member_text, " " }) };
            } else {
                edits[0] = .{ .start = object.start + 1, .end = object.start + 1, .text = try std.mem.concat(allocator, u8, &.{ " ", member_text }) };
            }
            return 1;
        }
        const last = object.members[object.members.len - 1];
        const anchor = if (last.comma) |comma| comma + 1 else last.value.end;
        if (spans_lines) {
            if (lineBreakAfter(source, anchor)) |line_break| {
                if (ownLineIndentation(source, last.key_start)) |indentation| {
                    var count: usize = 0;
                    if (last.comma == null) {
                        edits[count] = .{ .start = last.value.end, .end = last.value.end, .text = "," };
                        count += 1;
                    }
                    const trailing_comma: []const u8 = if (last.comma != null) "," else "";
                    edits[count] = .{ .start = line_break, .end = line_break, .text = try std.mem.concat(allocator, u8, &.{ style.newline, indentation, member_text, trailing_comma }) };
                    return count + 1;
                }
            }
        }
        if (last.comma != null) {
            edits[0] = .{ .start = anchor, .end = anchor, .text = try std.mem.concat(allocator, u8, &.{ " ", member_text }) };
        } else {
            edits[0] = .{ .start = last.value.end, .end = last.value.end, .text = try std.mem.concat(allocator, u8, &.{ ", ", member_text }) };
        }
        return 1;
    }
};

/// The edits that remove object.members[index]: its whole line when it stands on lines of its
/// own (with a comment at the end of its last line), else its text, the block comments after it
/// on its line and one comma. A last member without a comma of its own also takes the comma
/// before it, so a file written without trailing commas keeps none; comments between that comma
/// and the member stay, since they may be about the member before.
fn removalEdits(source: []const u8, object: *const Value, index: usize, edits: *[2]Edit) usize {
    const member = object.members[index];
    const member_end = if (member.comma) |comma| comma + 1 else member.value.end;
    const previous_comma: ?usize = if (index > 0) object.members[index - 1].comma else null;
    if (ownLineIndentation(source, member.key_start)) |indentation| {
        if (lineBreakAfter(source, member_end)) |line_break| {
            var end = line_break;
            if (end < source.len and source[end] == '\r') end += 1;
            if (end < source.len and source[end] == '\n') end += 1;
            var count: usize = 0;
            if (member.comma == null) {
                if (previous_comma) |comma| {
                    edits[count] = .{ .start = comma, .end = comma + 1, .text = "" };
                    count += 1;
                }
            }
            edits[count] = .{ .start = member.key_start - indentation.len, .end = end, .text = "" };
            return count + 1;
        }
    }
    if (member.comma) |comma| {
        var end = comma + 1;
        while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
        edits[0] = .{ .start = member.key_start, .end = end, .text = "" };
        return 1;
    }
    const value_end = sameLineCommentsEnd(source, member.value.end);
    if (previous_comma) |comma| {
        var start = member.key_start;
        while (start > comma + 1 and (source[start - 1] == ' ' or source[start - 1] == '\t')) start -= 1;
        edits[0] = .{ .start = comma, .end = comma + 1, .text = "" };
        edits[1] = .{ .start = start, .end = value_end, .text = "" };
        return 2;
    }
    var start = member.key_start;
    while (start > object.start + 1 and isBlank(source[start - 1 .. start])) start -= 1;
    // After a comment, one blank stays before the closing brace.
    if (start > object.start + 1 and start < member.key_start) start += 1;
    var end = value_end;
    while (end < object.end - 1 and isBlank(source[end .. end + 1])) end += 1;
    edits[0] = .{ .start = start, .end = end, .text = "" };
    return 1;
}

fn parseValueText(allocator: std.mem.Allocator, value_text: []const u8) Error!*const json.Node {
    const wrapped = try std.mem.concat(allocator, u8, &.{ "{\"value\": ", value_text, "}" });
    const root = parseChecked(allocator, wrapped) catch return error.EditFailed;
    return root.get("value") orelse error.EditFailed;
}

const testing = std.testing;

fn expectSet(source: []const u8, path: []const []const u8, value_text: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var editor = try Editor.init(arena_state.allocator(), source);
    try editor.set(path, value_text);
    try testing.expectEqualStrings(expected, editor.text());
}

fn expectRemove(source: []const u8, path: []const []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var editor = try Editor.init(arena_state.allocator(), source);
    try editor.remove(path);
    try testing.expectEqualStrings(expected, editor.text());
}

test "a value is replaced in place and everything around it stays" {
    try expectSet(
        \\{
        \\  // every device
        \\  "lighting": {
        \\    "*": { "*": { "effect": "static", "color": "#FFFFFF" } } /* all white */
        \\  }
        \\}
        \\
    , &.{ "lighting", "*", "*", "color" }, "\"#0000FF\"",
        \\{
        \\  // every device
        \\  "lighting": {
        \\    "*": { "*": { "effect": "static", "color": "#0000FF" } } /* all white */
        \\  }
        \\}
        \\
    );
}

test "a key joins a one-line object on its line" {
    try expectSet("{ \"zone\": { \"effect\": \"static\", \"color\": \"#FFFFFF\" } }", &.{ "zone", "speed" }, "40", "{ \"zone\": { \"effect\": \"static\", \"color\": \"#FFFFFF\", \"speed\": 40 } }");
    try expectSet("{ \"zone\": { \"effect\": \"static\", } }", &.{ "zone", "speed" }, "40", "{ \"zone\": { \"effect\": \"static\", \"speed\": 40 } }");
    try expectSet("{ \"zone\": {} }", &.{ "zone", "speed" }, "40", "{ \"zone\": { \"speed\": 40 } }");
}

test "a member goes on a new line after the last one, after its comment, with a comma added" {
    try expectSet(
        \\{
        \\  "lighting": {
        \\    "gpu": {
        \\      "fan_left": { "effect": "cycle" } // left fan
        \\    }
        \\  }
        \\}
    , &.{ "lighting", "gpu", "fan_right", "effect" }, "\"static\"",
        \\{
        \\  "lighting": {
        \\    "gpu": {
        \\      "fan_left": { "effect": "cycle" }, // left fan
        \\      "fan_right": { "effect": "static" }
        \\    }
        \\  }
        \\}
    );
}

test "a trailing comma after the last member is kept for the new last member" {
    try expectSet(
        \\{
        \\  "plugins": {
        \\    "keychron": { "persist": true },
        \\  },
        \\}
    , &.{ "plugins", "corsair_ddr5", "enabled" }, "true",
        \\{
        \\  "plugins": {
        \\    "keychron": { "persist": true },
        \\    "corsair_ddr5": { "enabled": true },
        \\  },
        \\}
    );
}

test "missing objects are created on lines of their own around a one-line zone" {
    try expectSet(
        \\{
        \\  "frame_rate": 30
        \\}
        \\
    , &.{ "lighting", "gpu", "fan_left", "effect" }, "\"static\"",
        \\{
        \\  "frame_rate": 30,
        \\  "lighting": {
        \\    "gpu": {
        \\      "fan_left": { "effect": "static" }
        \\    }
        \\  }
        \\}
        \\
    );
    try expectSet("{}", &.{ "lighting", "*", "*", "effect" }, "\"off\"",
        \\{
        \\  "lighting": {
        \\    "*": {
        \\      "*": { "effect": "off" }
        \\    }
        \\  }
        \\}
    );
}

test "an empty or comment-only file gets a top-level object" {
    try expectSet("", &.{ "plugins", "keychron", "enabled" }, "false",
        \\{
        \\  "plugins": {
        \\    "keychron": { "enabled": false }
        \\  }
        \\}
        \\
    );
    try expectSet("// my settings", &.{"frame_rate"}, "30",
        \\// my settings
        \\{
        \\  "frame_rate": 30
        \\}
        \\
    );
}

test "inserted lines use the file's line breaks, indentation and byte order mark" {
    try expectSet("{\r\n  \"a\": 1\r\n}\r\n", &.{"b"}, "2", "{\r\n  \"a\": 1,\r\n  \"b\": 2\r\n}\r\n");
    try expectSet("{\n\t\"a\": {\n\t\t\"x\": 1\n\t}\n}\n", &.{ "c", "d", "e" }, "1", "{\n\t\"a\": {\n\t\t\"x\": 1\n\t},\n\t\"c\": {\n\t\t\"d\": { \"e\": 1 }\n\t}\n}\n");
    try expectSet("\xEF\xBB\xBF{\n    \"a\": 1\n}\n", &.{"b"}, "[\"#FF0000\", \"#00FF00\"]", "\xEF\xBB\xBF{\n    \"a\": 1,\n    \"b\": [\"#FF0000\", \"#00FF00\"]\n}\n");
}

test "the last of duplicated keys is the one changed" {
    try expectSet("{ \"a\": 1, \"a\": 2 }", &.{"a"}, "3", "{ \"a\": 1, \"a\": 3 }");
}

test "keys with escapes are matched by their text" {
    try expectSet("{ \"g\\u0070u\": { \"x\": 1 } }", &.{ "gpu", "x" }, "2", "{ \"g\\u0070u\": { \"x\": 2 } }");
}

test "a value that is not an object on the path is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var editor = try Editor.init(arena_state.allocator(), "{ \"lighting\": \"none\" }");
    try testing.expectError(error.NotAnObject, editor.set(&.{ "lighting", "gpu", "effect" }, "\"off\""));
    try testing.expectEqualStrings("{ \"lighting\": \"none\" }", editor.text());
    try testing.expectError(error.Syntax, Editor.init(arena_state.allocator(), "{ \"a\": }"));
    try testing.expectError(error.EditFailed, editor.set(&.{"frame_rate"}, "30 30"));
}

test "a member on its own line is removed with its line and its end-of-line comment" {
    try expectRemove(
        \\{
        \\  "lighting": {
        \\    // the GPU
        \\    "gpu": { "effect": "static" }, // fans and logos
        \\    "ram": { "effect": "off" }
        \\  }
        \\}
    , &.{ "lighting", "gpu" },
        \\{
        \\  "lighting": {
        \\    // the GPU
        \\    "ram": { "effect": "off" }
        \\  }
        \\}
    );
    try expectRemove("{\r\n  \"a\": 1,\r\n  \"b\": 2\r\n}\r\n", &.{"b"}, "{\r\n  \"a\": 1\r\n}\r\n");
    try expectRemove("{\n  \"a\": 1,\n  \"b\": 2,\n}\n", &.{"b"}, "{\n  \"a\": 1,\n}\n");
}

test "members of a one-line object are removed with one comma" {
    try expectRemove("{ \"a\": 1, \"b\": 2, \"c\": 3 }", &.{"b"}, "{ \"a\": 1, \"c\": 3 }");
    try expectRemove("{ \"a\": 1, \"b\": 2, \"c\": 3 }", &.{"a"}, "{ \"b\": 2, \"c\": 3 }");
    try expectRemove("{ \"a\": 1, \"b\": 2, \"c\": 3 }", &.{"c"}, "{ \"a\": 1, \"b\": 2 }");
    try expectRemove("{ \"z\": { \"effect\": \"off\" } }", &.{ "z", "effect" }, "{ \"z\": {} }");
}

test "every copy of a duplicated key is removed and a missing key is no error" {
    try expectRemove("{ \"a\": 1, \"b\": 2, \"a\": 3 }", &.{"a"}, "{ \"b\": 2 }");
    try expectRemove("{ \"a\": 1 }", &.{ "x", "y" }, "{ \"a\": 1 }");
    try expectRemove("{ \"a\": 1 }", &.{ "a", "y" }, "{ \"a\": 1 }");
}

fn duplicatedKeys(allocator: std.mem.Allocator, count: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "{ \"keep\": 0");
    for (0..count) |_| try out.appendSlice(allocator, ", \"a\": 1");
    try out.appendSlice(allocator, " }");
    return out.items;
}

test "up to 64 copies of a key are removed; with more the text stays as it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var editor = try Editor.init(arena, try duplicatedKeys(arena, 64));
    try editor.remove(&.{"a"});
    try testing.expectEqualStrings("{ \"keep\": 0 }", editor.text());
    const too_many = try duplicatedKeys(arena, 65);
    editor = try Editor.init(arena, too_many);
    try testing.expectError(error.EditFailed, editor.remove(&.{"a"}));
    try testing.expectEqualStrings(too_many, editor.text());
}

test "an edit that fails leaves the text as it was, even an empty one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var editor = try Editor.init(arena_state.allocator(), "// nothing yet\n");
    const too_deep: [70][]const u8 = @splat("k");
    try testing.expectError(error.EditFailed, editor.set(&too_deep, "1"));
    try testing.expectEqualStrings("// nothing yet\n", editor.text());
}

test "a block comment after the last member stays with it when a member is added" {
    try expectSet(
        \\{
        \\  "a": 1 /* about a,
        \\     over two lines */
        \\}
    , &.{"b"}, "2",
        \\{
        \\  "a": 1, /* about a,
        \\     over two lines */
        \\  "b": 2
        \\}
    );
}

test "comments around a removed member of a one-line object go only with it" {
    try expectRemove("{ \"a\": 1, /* about a */ \"b\": 2 }", &.{"b"}, "{ \"a\": 1 /* about a */ }");
    try expectRemove("{ \"a\": 1, \"b\": 2 /* about b */ }", &.{"b"}, "{ \"a\": 1 }");
    try expectRemove("{ \"a\": 1 /* about a */ }", &.{"a"}, "{}");
    try expectRemove("{ /* header */ \"a\": 1 }", &.{"a"}, "{ /* header */ }");
}

test "empty objects are removed, ones holding a comment are kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var editor = try Editor.init(arena_state.allocator(), "{ \"lighting\": { \"gpu\": { \"fan\": {} }, \"ram\": { /* later */ } } }");
    try editor.removeIfEmpty(&.{ "lighting", "gpu", "fan" });
    try editor.removeIfEmpty(&.{ "lighting", "gpu" });
    try editor.removeIfEmpty(&.{ "lighting", "ram" });
    try testing.expectEqualStrings("{ \"lighting\": { \"ram\": { /* later */ } } }", editor.text());
}

test "a configuration with comments keeps every comment through a series of edits" {
    const source =
        \\{
        \\  // Sample profile: every device solid blue.
        \\  "lighting": {
        \\    // Every device, every zone.
        \\    "*": {
        \\      "*": { "effect": "static", "color": "#0000FF" }
        \\    },
        \\
        \\    // The ARGB headers need a length.
        \\    "motherboard": {
        \\      "argb1": { "leds": 30 },
        \\      "io_cover": { "effect": "static", "color": "#0000FF" } // AORUS logo
        \\    }
        \\  },
        \\
        \\  "plugins": {
        \\    // The SK700V display keeps showing CPU stats.
        \\    "sudokoo_sk700v": { "temperature_unit": "C" }
        \\  }
        \\}
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var editor = try Editor.init(arena_state.allocator(), source);
    try editor.set(&.{ "lighting", "motherboard", "io_cover", "effect" }, "\"breathing\"");
    try editor.set(&.{ "lighting", "motherboard", "io_cover", "colors" }, "[\"#FF0000\", \"#00FF00\"]");
    try editor.remove(&.{ "lighting", "motherboard", "io_cover", "color" });
    try editor.set(&.{ "lighting", "motherboard", "io_cover", "speed" }, "70");
    try editor.set(&.{ "lighting", "gpu", "fan_left", "effect" }, "\"rainbow\"");
    try editor.set(&.{ "plugins", "keychron", "enabled" }, "false");
    try editor.remove(&.{ "lighting", "motherboard", "argb1", "leds" });
    try editor.removeIfEmpty(&.{ "lighting", "motherboard", "argb1" });
    try testing.expectEqualStrings(
        \\{
        \\  // Sample profile: every device solid blue.
        \\  "lighting": {
        \\    // Every device, every zone.
        \\    "*": {
        \\      "*": { "effect": "static", "color": "#0000FF" }
        \\    },
        \\
        \\    // The ARGB headers need a length.
        \\    "motherboard": {
        \\      "io_cover": { "effect": "breathing", "colors": ["#FF0000", "#00FF00"], "speed": 70 } // AORUS logo
        \\    },
        \\    "gpu": {
        \\      "fan_left": { "effect": "rainbow" }
        \\    }
        \\  },
        \\
        \\  "plugins": {
        \\    // The SK700V display keeps showing CPU stats.
        \\    "sudokoo_sk700v": { "temperature_unit": "C" },
        \\    "keychron": { "enabled": false }
        \\  }
        \\}
        \\
    , editor.text());
}
