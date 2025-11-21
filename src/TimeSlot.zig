//! A combination of class conferences held concurrently.
//!
//! Associated with a `Restrictions`.
//!
//! Asserts `associated_restrictions.room_count > 0`.
//! Asserts amount of classes <= `options.class_limit`

const std = @import("std");
const options = @import("options");

const Restrictions = @import("Restrictions.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const TeacherBitboard = Restrictions.Class.TeacherBitboard;

const TimeSlot = @This();

bitboard: ClassBitboard,

pub const ClassBitboard = std.meta.Int(.unsigned, options.class_limit);
pub const ClassId = std.math.Log2Int(ClassBitboard);
pub const ClassIdCeil = std.math.Log2IntCeil(ClassBitboard);

fn classesMandatoryOverlap(ts_classes: []const ClassId, restrictions: Restrictions) TeacherBitboard {
    var outp: TeacherBitboard = 0;
    for (ts_classes, 0..) |ci_0, i| {
        const class_0 = restrictions.classes[ci_0];
        for (ts_classes[(i + 1)..]) |ci_1| {
            const class_1 = restrictions.classes[ci_1];
            outp |= class_0.intersection(class_1).mandatory;
        }
    }
    return outp;
}
fn classesHasMandatoryOverlap(ts_classes: []const ClassId, restrictions: Restrictions) bool {
    return classesMandatoryOverlap(ts_classes, restrictions) != 0;
}
pub fn mandatoryOverlap(ts: TimeSlot, restrictions: Restrictions) TeacherBitboard {
    // Create an FBA to circumvent having to pass a gpa.
    // With default settings, this is gonna be around
    // 256 bytes extra on the stack.
    var buf: [options.class_limit * @sizeOf(ClassId)]u8 = undefined;
    var buffer_allocator = std.heap.FixedBufferAllocator.init(&buf);
    const arena = buffer_allocator.allocator();

    const ts_classes = ts.classes(arena) catch |err| switch (err) {
        error.OutOfMemory => unreachable,
    };
    return classesMandatoryOverlap(ts_classes, restrictions);
}
/// Returns `true` iff one or more teachers are mandatory twice or more.
pub fn hasMandatoryOverlap(ts: TimeSlot, restrictions: Restrictions) bool {
    return ts.mandatoryOverlap(restrictions) != 0;
}

pub fn classesLength(ts: TimeSlot) usize {
    return @popCount(ts.bitboard);
}
/// Indexes into `associated_restrictions.classes`.
///
/// Asserts `ts` has a length of at least 1.
///
/// Uses at most `options.class_limit * @sizeOf(ClassId)` bytes.
pub fn classes(ts: TimeSlot, gpa: Allocator) Allocator.Error![]ClassId {
    const outp = try gpa.alloc(ClassId, ts.classesLength());
    errdefer gpa.free(outp);

    assert(outp.len > 0);
    var i: usize = 0;
    for (0..options.class_limit) |class_id| {
        const mask = @shlExact(@as(ClassBitboard, 1), @intCast(class_id));
        if (ts.bitboard & mask != 0) {
            outp[i] = @intCast(class_id);
            i += 1;
            if (i >= outp.len) return outp;
        }
    }
    unreachable;
}
pub fn fromClasses(ts_classes: []const ClassId) TimeSlot {
    var bitboard: ClassBitboard = 0;
    for (ts_classes) |c| {
        bitboard |= @shlExact(@as(ClassBitboard, 1), c);
    }
    return .{ .bitboard = bitboard };
}

pub fn eql(a: TimeSlot, b: TimeSlot) bool {
    return a.bitboard == b.bitboard;
}

/// Generates all possible non-overlapping time slots.
///
/// Asserts `restrictions.classes.len >= restrictions.root_count`.
pub fn generateTimeSlots(gpa: Allocator, restrictions: Restrictions, progress_root: std.Progress.Node) Allocator.Error![]TimeSlot {
    const combinations: usize = blk: { // n choose k
        const n = restrictions.classes.len;
        const k = restrictions.room_count;
        assert(n >= k);

        var o: usize = 1;
        for ((n - k + 1)..(n + 1)) |i| o *= i;
        for (2..(k + 1)) |i| o = @divExact(o, i);
        break :blk o;
    };

    const progress_generate_ts = progress_root.start("Generate possible time slots", 0);
    defer progress_generate_ts.end();
    const progress_tested = progress_generate_ts.start("Combinations tested", combinations);
    defer progress_tested.end();
    const progress_valid = progress_generate_ts.start("Valid combinations found", 0);
    defer progress_valid.end();

    var outp_list: std.ArrayList(TimeSlot) = .empty;
    errdefer outp_list.deinit(gpa);

    const ts_classes = try gpa.alloc(ClassId, restrictions.room_count);
    defer gpa.free(ts_classes);
    for (ts_classes, 0..) |*idx, i| {
        idx.* = @intCast(i);
    }

    while (true) : (if (!increaseIndecies(ts_classes, @intCast(restrictions.classes.len))) break) {
        defer progress_tested.completeOne();

        if (classesHasMandatoryOverlap(ts_classes, restrictions)) continue;

        const time_slot: TimeSlot = .fromClasses(ts_classes);
        try outp_list.append(gpa, time_slot);

        progress_valid.completeOne();
    }

    return try outp_list.toOwnedSlice(gpa);
}

/// Increases `indecies` such that `indecies[i] < indecies[i - 1]`
/// and `indecies[i] < max`.
///
/// Returns `false` if `indecies` can no longer be increased.
fn increaseIndecies(indecies: []ClassId, max: ClassIdCeil) bool {
    for (0..indecies.len) |i_inv| {
        const i = indecies.len - 1 - i_inv;
        indecies[i] += 1;

        const actual_max = if (i + 1 >= indecies.len) max else indecies[i + 1];
        if (indecies[i] < actual_max) {
            @branchHint(.likely); // TODO: Performance test this.
            return true;
        }

        assert(i > 0);

        indecies[i] = indecies[i - 1] + 2;
        if (indecies[i] >= actual_max) {
            assert(i == indecies.len - 1);
            return false; // Hit maximum.
        }
    }
    unreachable;
}
