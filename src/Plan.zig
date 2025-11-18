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

const Plan = @This();

/// Length guarantied to be <= `associated_restrictions.time_slots`.
/// Time slots should be correct (have no mandatory overlap).
time_slots: []const TimeSlot,

pub fn classOverlap(plan: Plan) ClassBitboard {
    var outp: ClassBitboard = 0;
    for (plan.time_slots, 0..) |ts_0, i| {
        for (plan.time_slots[(i + 1)..]) |ts_1| {
            outp |= ts_0.classes_bitboard & ts_1.classes_bitboard;
        }
    }
    return outp;
}
/// Returns `true` iff one or more classes appears twice or more.
pub fn hasClassOverlap(plan: Plan) bool {
    return plan.classOverlap() != 0;
}

/// Generates all possible plans without a repeating class.
///
/// Asserts that all classes can be covered within the number
/// of time slots and rooms.
///
/// The plans themselves and the time slots they contain have
/// to be freed too!
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
    //defer progress_tested.end();
    const progress_valid = progress_generate_plans.start("Valid combinations found", 0);
    //defer progress_valid.end();

    var remaining_arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer remaining_arena_allocator.deinit();
    const remaining_arena = remaining_arena_allocator.allocator();

    // This one copies `time_slots`.
    var outp: std.ArrayList(Plan) = .empty;
    errdefer {
        for (outp.items) |plan| {
            plan.free(gpa);
        }
        outp.deinit(gpa);
    }

    // This one uses `time_slots`.
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
            current_branch.free(gpa);
            continue;
        }

        if (current_branch.time_slots.len == full_time_slots + additional_time_slot) {
            defer gpa.free(current_branch.time_slots);

            const plan_as_time_slots = try gpa.alloc(TimeSlot, current_branch.time_slots.len);
            errdefer gpa.free(plan_as_time_slots);
            var done: usize = 0;
            errdefer for (plan_as_time_slots[0..done]) |ts| {
                gpa.free(ts.classes);
            };
            for (plan_as_time_slots, current_branch.time_slots) |*new, current| {
                new.classes_bitboard = current.classes_bitboard;
                new.classes = try gpa.dupe(ClassId, current.classes);
                errdefer gpa.free(new.classes);
                done += 1;
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
                    o |= ts.classes_bitboard;
                }
                break :blk o;
            };
            const needed_bitboard = (~covered_bitboard) & (@as(ClassBitboard, std.math.maxInt(ClassBitboard)) >> @intCast(options.class_limit - restrictions.classes.len));
            assert(@popCount(needed_bitboard) == remaining_classes);

            const needed_classes = try remaining_arena.alloc(ClassId, remaining_classes);
            var insert_i: usize = 0;
            for (0..options.class_limit) |class_id| {
                const mask = @shlExact(@as(ClassBitboard, 1), @intCast(class_id));
                if (needed_bitboard & mask != 0) {
                    needed_classes[insert_i] = @intCast(class_id);
                    insert_i += 1;
                    if (insert_i >= needed_classes.len) break;
                }
            }

            const needed: TimeSlot = .{
                .classes = needed_classes,
                .classes_bitboard = needed_bitboard,
            };

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

pub fn free(p: Plan, gpa: Allocator) void {
    for (p.time_slots) |ts| {
        gpa.free(ts.classes);
    }
    gpa.free(p.time_slots);
}
