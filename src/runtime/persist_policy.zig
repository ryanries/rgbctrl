const std = @import("std");
const sdk = @import("sdk");

const win32 = sdk.win32;
const abi = sdk.abi;

const cooldown_ms: u64 = 60_000;
const start_delay_ms: u64 = 60_000;
const settle_ms: u64 = 60_000;
const unsaved_warning_ms: u64 = 600_000;

const Failure = enum { none, busy, failed };

pub const State = struct {
    dirty: bool = false,
    dirty_since_ms: u64 = 0,
    changed_at_ms: u64 = 0,
    last_attempt_ms: ?u64 = null,
    last_failure: Failure = .none,
    warned: bool = false,

    pub fn markDirty(self: *State, now_ms: u64) void {
        if (!self.dirty) {
            self.dirty = true;
            self.dirty_since_ms = now_ms;
            self.warned = false;
        }
        self.changed_at_ms = now_ms;
    }

    pub fn clear(self: *State) void {
        self.dirty = false;
        self.warned = false;
        self.last_failure = .none;
    }

    /// A save waits until the settings have been unchanged for a minute, so it never lands right
    /// after a write and does not store every step of an interactive edit.
    pub fn eligibleAt(self: *const State) ?u64 {
        if (!self.dirty) return null;
        const after_cooldown = if (self.last_attempt_ms) |last| last + cooldown_ms else 0;
        return @max(after_cooldown, start_delay_ms, self.changed_at_ms + settle_ms);
    }

    pub fn recordResult(self: *State, status: i32, now_ms: u64) void {
        self.last_attempt_ms = now_ms;
        if (status == abi.status_ok) {
            self.clear();
        } else {
            self.last_failure = if (status == abi.status_busy) .busy else .failed;
        }
    }

    pub fn takeUnsavedWarning(self: *State, now_ms: u64) bool {
        if (!self.dirty or self.warned or now_ms -| self.dirty_since_ms < unsaved_warning_ms) return false;
        self.warned = true;
        return true;
    }
};

const FinalDecision = union(enum) {
    nothing,
    persist,
    skipped: []const u8,
};

pub fn finalDecision(state: *const State, now_ms: u64) FinalDecision {
    if (!state.dirty) return .nothing;
    if (now_ms < start_delay_ms) return .{ .skipped = "start delay" };
    if (state.last_attempt_ms) |last| {
        if (now_ms < last + cooldown_ms) return .{ .skipped = if (state.last_failure == .busy) "busy" else "cooldown" };
    }
    return .persist;
}

pub const Registry = struct {
    lock: win32.SRWLOCK = .{},
    allocator: std.mem.Allocator,
    keys: std.ArrayList([]const u8) = .empty,
    states: std.ArrayList(*State) = .empty,

    pub fn get(self: *Registry, key: []const u8) ?*State {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        for (self.keys.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, key)) return self.states.items[index];
        }
        const owned_key = self.allocator.dupe(u8, key) catch return null;
        const state = self.allocator.create(State) catch return null;
        state.* = .{};
        self.keys.append(self.allocator, owned_key) catch return null;
        self.states.append(self.allocator, state) catch {
            _ = self.keys.pop();
            return null;
        };
        return state;
    }
};

const testing = std.testing;

test "a clean device is never eligible and a dirty one waits for the start delay and a quiet minute" {
    var state = State{};
    try testing.expect(state.eligibleAt() == null);
    state.markDirty(0);
    try testing.expectEqual(@as(?u64, 60_000), state.eligibleAt());
    state.markDirty(5_000);
    try testing.expectEqual(@as(?u64, 65_000), state.eligibleAt());
}

test "every change restarts the quiet minute but not the unsaved warning" {
    var state = State{};
    state.markDirty(100_000);
    try testing.expectEqual(@as(?u64, 160_000), state.eligibleAt());
    state.markDirty(150_000);
    try testing.expectEqual(@as(?u64, 210_000), state.eligibleAt());
    try testing.expectEqual(@as(u64, 100_000), state.dirty_since_ms);
}

test "every attempt starts a 60 second cooldown and success clears the dirty flag" {
    var state = State{};
    state.markDirty(70_000);
    try testing.expectEqual(@as(?u64, 130_000), state.eligibleAt());
    state.recordResult(abi.status_busy, 130_000);
    try testing.expect(state.dirty);
    try testing.expectEqual(Failure.busy, state.last_failure);
    try testing.expectEqual(@as(?u64, 190_000), state.eligibleAt());
    state.recordResult(abi.status_ok, 190_000);
    try testing.expect(!state.dirty);
    try testing.expect(state.eligibleAt() == null);
    state.markDirty(191_000);
    try testing.expectEqual(@as(?u64, 251_000), state.eligibleAt());
    state.markDirty(245_000);
    try testing.expectEqual(@as(?u64, 305_000), state.eligibleAt());
}

test "a device that stays dirty for ten minutes warns once" {
    var state = State{};
    state.markDirty(1_000);
    try testing.expect(!state.takeUnsavedWarning(500_000));
    try testing.expect(state.takeUnsavedWarning(601_000));
    try testing.expect(!state.takeUnsavedWarning(900_000));
}

test "the final decision explains why a dirty device is not saved at exit" {
    var state = State{};
    try testing.expect(finalDecision(&state, 100_000) == .nothing);
    state.markDirty(10_000);
    try testing.expectEqualStrings("start delay", finalDecision(&state, 30_000).skipped);
    try testing.expect(finalDecision(&state, 61_000) == .persist);
    state.recordResult(abi.status_busy, 61_000);
    try testing.expectEqualStrings("busy", finalDecision(&state, 90_000).skipped);
    state.recordResult(abi.status_fail, 125_000);
    try testing.expectEqualStrings("cooldown", finalDecision(&state, 150_000).skipped);
    try testing.expect(finalDecision(&state, 186_000) == .persist);
}

test "the registry returns the same state for the same device key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var registry = Registry{ .allocator = arena_state.allocator() };
    const first = registry.get("keychron.keyboard").?;
    first.markDirty(1);
    try testing.expect(registry.get("keychron.keyboard").?.dirty);
    try testing.expect(!registry.get("gigabyte_gpu.gpu").?.dirty);
}
