//! Associated with a `Restrictions`.
//!
//! Asserts `associated_restrictions.time_slots > 0`.

const std = @import("std");
const options = @import("options");

const Restrictions = @import("Restrictions.zig");
const TimeSlot = @import("TimeSlot.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ClassBitboard = TimeSlot.ClassBitboard;
const ClassId = TimeSlot.ClassId;
const Writer = std.Io.Writer;

const Plan = @This();

pub const utils = @import("Plan/utils.zig");

/// Length guarantied to be <= `associated_restrictions.time_slots`.
/// Time slots should be correct (have no mandatory overlap).
time_slots: []const TimeSlot,

pub fn classOverlap(plan: Plan) ClassBitboard {
    var outp: ClassBitboard = 0;
    for (plan.time_slots, 0..) |ts_0, i| {
        for (plan.time_slots[(i + 1)..]) |ts_1| {
            outp |= ts_0.bitboard & ts_1.bitboard;
        }
    }
    return outp;
}
/// Returns `true` iff one or more classes appears twice or more.
pub fn hasClassOverlap(plan: Plan) bool {
    return plan.classOverlap() != 0;
}

/// Returns `true` iff `a` and `b` are the same plan except for
/// the time slots being in a different order.
///
/// Assumes no time slot in `a` or `b` repeats.
pub fn isShuffle(a: Plan, b: Plan) bool {
    if (a.time_slots.len != b.time_slots.len) return false;

    a_loop: for (a.time_slots) |a_ts| {
        for (b.time_slots) |b_ts| {
            if (a_ts.eql(b_ts)) continue :a_loop;
        }
        return false;
    }
    return true;
}

/// Generates all possible plans without a repeating class.
///
/// Asserts that all classes can be covered within the number
/// of time slots and rooms.
///
/// The plans themselves have to be freed too!
///
/// TODO: Make multithreaded.
pub fn generatePlans(gpa: Allocator, restrictions: Restrictions, time_slots: []const TimeSlot, progress_root: std.Progress.Node) Allocator.Error![]Plan {
    assert(restrictions.classes.len <= restrictions.room_count * restrictions.time_slots);

    const full_time_slots = restrictions.classes.len / restrictions.room_count;
    const remaining_classes = restrictions.classes.len % restrictions.room_count;
    const additional_time_slot = @intFromBool(remaining_classes != 0);
    assert(full_time_slots * restrictions.room_count + remaining_classes == restrictions.classes.len);

    const progress_generate_plans = progress_root.start("Generate possible plans", 0);
    defer progress_generate_plans.end();
    const progress_tested = progress_generate_plans.start("Branches tested", time_slots.len);
    defer progress_tested.end();
    const progress_valid = progress_generate_plans.start("Valid combinations found", 0);
    defer progress_valid.end();

    var outp: std.ArrayList(Plan) = .empty;
    errdefer {
        for (outp.items) |plan| {
            gpa.free(plan.time_slots);
        }
        outp.deinit(gpa);
    }

    var inbetweens = try std.ArrayList(Plan).initCapacity(gpa, time_slots.len);
    defer {
        for (inbetweens.items) |plan| {
            gpa.free(plan.time_slots);
        }
        inbetweens.deinit(gpa);
    }
    for (time_slots) |ts| {
        const plan_as_time_slots = try gpa.alloc(TimeSlot, 1);
        errdefer gpa.free(plan_as_time_slots);
        plan_as_time_slots[0] = ts;
        inbetweens.appendAssumeCapacity(.{ .time_slots = plan_as_time_slots });
    }

    while (inbetweens.pop()) |current_branch| {
        defer progress_tested.completeOne();

        if (current_branch.hasClassOverlap()) {
            gpa.free(current_branch.time_slots);
            continue;
        }

        if (current_branch.time_slots.len == full_time_slots + additional_time_slot) {
            defer gpa.free(current_branch.time_slots);

            const plan_as_time_slots = try gpa.alloc(TimeSlot, current_branch.time_slots.len);
            errdefer gpa.free(plan_as_time_slots);
            for (plan_as_time_slots, current_branch.time_slots) |*new, current| {
                new.bitboard = current.bitboard;
            }

            try outp.append(gpa, .{ .time_slots = plan_as_time_slots });
            progress_valid.completeOne();
            continue;
        }

        defer gpa.free(current_branch.time_slots);

        if (additional_time_slot == 1 and current_branch.time_slots.len == full_time_slots + additional_time_slot - 1) { // Just need remaining classes.
            assert(remaining_classes != 0);

            const covered_bitboard: ClassBitboard = blk: {
                var o: ClassBitboard = 0;
                for (current_branch.time_slots) |ts| {
                    o |= ts.bitboard;
                }
                break :blk o;
            };
            const needed_bitboard = (~covered_bitboard) & (@as(ClassBitboard, std.math.maxInt(ClassBitboard)) >> @intCast(options.class_limit - restrictions.classes.len));
            assert(@popCount(needed_bitboard) == remaining_classes);

            const needed: TimeSlot = .{ .bitboard = needed_bitboard };

            if (needed.hasMandatoryOverlap(restrictions)) continue;

            const plan_as_time_slots = try gpa.alloc(TimeSlot, current_branch.time_slots.len + 1);
            errdefer gpa.free(plan_as_time_slots);
            @memcpy(plan_as_time_slots[0..current_branch.time_slots.len], current_branch.time_slots);
            plan_as_time_slots[current_branch.time_slots.len] = needed;

            progress_tested.increaseEstimatedTotalItems(1);
            try inbetweens.append(gpa, .{ .time_slots = plan_as_time_slots });
        } else {
            progress_tested.increaseEstimatedTotalItems(time_slots.len);

            for (time_slots) |ts| {
                const plan_as_time_slots = try gpa.alloc(TimeSlot, current_branch.time_slots.len + 1);
                errdefer gpa.free(plan_as_time_slots);
                @memcpy(plan_as_time_slots[0..current_branch.time_slots.len], current_branch.time_slots);
                plan_as_time_slots[current_branch.time_slots.len] = ts;
                try inbetweens.append(gpa, .{ .time_slots = plan_as_time_slots });
            }
        }
    }

    return try outp.toOwnedSlice(gpa);
}

/// Asserts `restrictions.room_count <= options.class_limit`.
///
/// TODO: Make this better somehow.
pub fn format(plan: Plan, restrictions: Restrictions, w: *Writer) Writer.Error!void {
    // Create an FBA to circumvent having to pass a gpa.
    // With default settings, this is gonna be around
    // 256 bytes extra on the stack.
    assert(restrictions.room_count <= options.class_limit);
    var buf: [options.class_limit * @sizeOf(ClassId)]u8 = undefined;
    var buffer_allocator = std.heap.FixedBufferAllocator.init(&buf);
    const arena = buffer_allocator.allocator();

    for (plan.time_slots) |ts| {
        try w.print("{{ ", .{});

        const ts_classes = ts.classes(arena) catch unreachable;
        defer buffer_allocator.reset();

        for (ts_classes) |class_id| {
            const class_name = restrictions.classes[class_id].name;
            try w.print("{s} ", .{class_name});
        }

        try w.print("}}\n", .{});
    }
}
