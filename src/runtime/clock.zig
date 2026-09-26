const std = @import("std");
const sdk = @import("sdk");

const win32 = sdk.win32;

pub const Clock = struct {
    frequency: u64,
    start: u64,

    pub fn init() Clock {
        var frequency: i64 = 0;
        var counter: i64 = 0;
        _ = win32.QueryPerformanceFrequency(&frequency);
        _ = win32.QueryPerformanceCounter(&counter);
        return .{ .frequency = @intCast(@max(frequency, 1)), .start = @intCast(@max(counter, 0)) };
    }

    pub fn nowMs(self: *const Clock) u64 {
        var counter: i64 = 0;
        _ = win32.QueryPerformanceCounter(&counter);
        const elapsed = @as(u64, @intCast(@max(counter, 0))) -| self.start;
        return ticksToMs(elapsed, self.frequency);
    }
};

fn ticksToMs(ticks: u64, frequency: u64) u64 {
    return (ticks / frequency) * 1000 + (ticks % frequency) * 1000 / frequency;
}

const resume_threshold_ms: i64 = 2000;

pub const ResumeDetector = struct {
    baseline: i64,

    pub fn init() ResumeDetector {
        return .{ .baseline = sample() };
    }

    fn sample() i64 {
        var unbiased: u64 = 0;
        _ = win32.QueryUnbiasedInterruptTime(&unbiased);
        return divergence(win32.GetTickCount64(), unbiased);
    }

    pub fn check(self: *ResumeDetector) bool {
        return self.observe(sample());
    }

    pub fn observe(self: *ResumeDetector, current: i64) bool {
        if (current - self.baseline > resume_threshold_ms) {
            self.baseline = current;
            return true;
        }
        if (current < self.baseline) self.baseline = current;
        return false;
    }
};

fn divergence(tick_count_ms: u64, unbiased_100ns: u64) i64 {
    return @as(i64, @intCast(tick_count_ms)) - @as(i64, @intCast(unbiased_100ns / 10000));
}

test "ticksToMs converts without overflowing for long uptimes" {
    try std.testing.expectEqual(@as(u64, 1500), ticksToMs(15_000_000, 10_000_000));
    try std.testing.expectEqual(@as(u64, 100 * 365 * 24 * 3600 * 1000), ticksToMs(100 * 365 * 24 * 3600 * 10_000_000, 10_000_000));
}

test "the resume detector fires once when wall time outruns unbiased time by more than two seconds" {
    var detector = ResumeDetector{ .baseline = divergence(10_000, 10_000 * 10000) };
    try std.testing.expect(!detector.observe(divergence(11_000, 11_000 * 10000)));
    try std.testing.expect(!detector.observe(divergence(13_000, 11_500 * 10000)));
    try std.testing.expect(detector.observe(divergence(70_000, 12_000 * 10000)));
    try std.testing.expect(!detector.observe(divergence(71_000, 13_000 * 10000)));
}

test "the clock advances monotonically" {
    const clock = Clock.init();
    const first = clock.nowMs();
    win32.Sleep(20);
    try std.testing.expect(clock.nowMs() >= first + 15);
}
