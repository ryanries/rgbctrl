const std = @import("std");

const max_length = 63;

fn distance(first: []const u8, second: []const u8) u32 {
    if (first.len > max_length or second.len > max_length) return std.math.maxInt(u32);
    var two_back: [max_length + 1]u32 = undefined;
    var previous: [max_length + 1]u32 = undefined;
    var current: [max_length + 1]u32 = undefined;
    for (0..second.len + 1) |column| previous[column] = @intCast(column);
    for (first, 0..) |first_char, row_index| {
        current[0] = @intCast(row_index + 1);
        for (second, 0..) |second_char, column_index| {
            const cost: u32 = if (std.ascii.toLower(first_char) == std.ascii.toLower(second_char)) 0 else 1;
            var best = @min(previous[column_index + 1] + 1, current[column_index] + 1);
            best = @min(best, previous[column_index] + cost);
            if (row_index > 0 and column_index > 0 and
                std.ascii.toLower(first_char) == std.ascii.toLower(second[column_index - 1]) and
                std.ascii.toLower(first[row_index - 1]) == std.ascii.toLower(second_char))
            {
                best = @min(best, two_back[column_index - 1] + 1);
            }
            current[column_index + 1] = best;
        }
        two_back = previous;
        previous = current;
    }
    return previous[second.len];
}

pub fn closest(candidate: []const u8, options: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: u32 = 3;
    for (options) |option| {
        if (std.mem.eql(u8, option, candidate)) continue;
        const option_distance = distance(candidate, option);
        if (option_distance < best_distance) {
            best_distance = option_distance;
            best = option;
        }
    }
    return best;
}

test "distance counts insertions, deletions, substitutions and adjacent transpositions" {
    try std.testing.expectEqual(@as(u32, 0), distance("argb1", "argb1"));
    try std.testing.expectEqual(@as(u32, 1), distance("argb", "argb1"));
    try std.testing.expectEqual(@as(u32, 1), distance("agrb1", "argb1"));
    try std.testing.expectEqual(@as(u32, 1), distance("brightnes", "brightness"));
    try std.testing.expectEqual(@as(u32, 2), distance("colr", "colors"));
    try std.testing.expectEqual(@as(u32, 0), distance("ARGB1", "argb1"));
    try std.testing.expectEqual(@as(u32, 5), distance("", "speed"));
}

test "closest suggests the nearest option within two edits and nothing further away" {
    const options = [_][]const u8{ "effect", "color", "colors", "speed", "brightness" };
    try std.testing.expectEqualStrings("effect", closest("efect", &options).?);
    try std.testing.expectEqualStrings("speed", closest("sped", &options).?);
    try std.testing.expectEqualStrings("brightness", closest("brigthness", &options).?);
    try std.testing.expect(closest("temperature", &options) == null);
}

test "an exact match is not suggested as a correction" {
    const options = [_][]const u8{"color"};
    try std.testing.expect(closest("color", &options) == null);
}
