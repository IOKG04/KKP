//! A combination of class conferences held concurrently.
//!
//! Associated with a `Restrictions`.
//! Asserts `associated_restrictions.room_count > 0`.

const std = @import("std");

const Restrictions = @import("Restrictions.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const TeacherBitboard = Restrictions.TeacherBitboard;

const TimeSlot = @This();

/// Indexes into `associated_restrictions.classes`.
///
/// Length guarantied to equal `associated_restrictions.room_count`.
classes: []const usize,

pub fn mandatoryOverlap(ts: TimeSlot, restrictions: Restrictions) TeacherBitboard {
    var outp: TeacherBitboard = 0;
    for (ts.classes, 0..) |ci_0, i| {
        const class_0 = restrictions.classes[ci_0];
        for (ts.classes[(i + 1)..]) |ci_1| {
            const class_1 = restrictions.classes[ci_1];
            outp |= class_0.mandatory_bitboard & class_1.mandatory_bitboard;
        }
    }
    return outp;
}
pub fn hasMandatoryOverlap(ts: TimeSlot, restrictions: Restrictions) bool {
    return ts.mandatoryOverlap(restrictions) != 0;
}

/// Generates all possible non-overlapping time slots.
///
/// Asserts `restrictions.classes.len >= restrictions.root_count`.
/// The time slots themselves have to be freed too!
///
/// TODO: Make multithreaded.
pub fn generateTimeSlots(gpa: Allocator, restrictions: Restrictions, progress_root: std.Progress.Node) Allocator.Error![]const TimeSlot {
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
    const progress_valid = progress_generate_ts.start("Valid combinations found", 0);

    var outp_list: std.ArrayList(TimeSlot) = .empty;
    errdefer outp_list.deinit(gpa);
    errdefer {
        for (outp_list.items) |item| {
            gpa.free(item.classes);
        }
    }

    const indecies = try gpa.alloc(usize, restrictions.room_count);
    defer gpa.free(indecies);
    for (indecies, 0..) |*idx, i| {
        idx.* = i;
    }

    while (true) : (if (!increaseIndecies(indecies, restrictions.classes.len)) break) {
        defer progress_tested.completeOne();

        const pseudo_time_slot: TimeSlot = .{ .classes = indecies };
        if (pseudo_time_slot.hasMandatoryOverlap(restrictions)) {
            continue;
        }

        const time_slot: TimeSlot = .{
            .classes = try gpa.dupe(usize, indecies),
        };
        errdefer gpa.free(time_slot.classes);
        try outp_list.append(gpa, time_slot);

        progress_valid.completeOne();
    }

    return try outp_list.toOwnedSlice(gpa);
}

/// Increases `indecies` such that `indecies[i] < indecies[i - 1]`
/// and `indecies[i] < max`.
///
/// Returns `false` if `indecies` can no longer be increased.
fn increaseIndecies(indecies: []usize, max: usize) bool {
    for (0..indecies.len) |i_inv| {
        const i = indecies.len - 1 - i_inv;
        indecies[i] += 1;

        const actual_max = if (i + 1 >= indecies.len) max else indecies[i + 1];
        if (indecies[i] < actual_max) {
            @branchHint(.likely);
            return true;
        }

        assert(i > 0);

        indecies[i] = indecies[i - 1] + 2;
        if (indecies[i] >= actual_max) return false; // Hit maximum.
    }
    unreachable;
}
