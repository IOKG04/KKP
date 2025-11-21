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

    const Inbetween = union (enum) {
        /// Index into `time_slots`.
        idx: usize,
        time_slot: TimeSlot,
        pub fn read(i: @This(), tss: []const TimeSlot) TimeSlot {
            return switch (i) {
                .idx => |idx| tss[idx],
                .time_slot => |ts| ts,
            };
        }
    };

    var inbetweenss = try std.ArrayList([]Inbetween).initCapacity(gpa, time_slots.len);
    defer {
        for (inbetweenss.items) |inbetweens| {
            gpa.free(inbetweens);
        }
        inbetweenss.deinit(gpa);
    }
    for (0..time_slots.len) |idx| {
        const inbetweens = try gpa.alloc(Inbetween, 1);
        errdefer gpa.free(inbetweens);
        inbetweens[0] = .{ .idx = idx };
        inbetweenss.appendAssumeCapacity(inbetweens);
    }

    while (inbetweenss.pop()) |current_branch| {
        defer progress_tested.completeOne();
        defer gpa.free(current_branch);

        if (has_class_overlap: {
            for (current_branch, 0..) |inbetween_0, i| {
                for (current_branch[(i + 1)..]) |inbetween_1| {
                    if (inbetween_0.read(time_slots).bitboard & inbetween_1.read(time_slots).bitboard != 0) break :has_class_overlap true;
                }
            }
            break :has_class_overlap false;
        }) continue;

        if (current_branch.len == full_time_slots + additional_time_slot) {
            const plan_as_time_slots = try gpa.alloc(TimeSlot, current_branch.len);
            errdefer gpa.free(plan_as_time_slots);
            for (plan_as_time_slots, current_branch) |*new, current| {
                new.* = current.read(time_slots);
            }

            try outp.append(gpa, .{ .time_slots = plan_as_time_slots });
            progress_valid.completeOne();
            continue;
        }

        if (additional_time_slot == 1 and current_branch.len == full_time_slots + additional_time_slot - 1) { // Just need remaining classes.
            assert(remaining_classes != 0);

            const covered_bitboard: ClassBitboard = blk: {
                var o: ClassBitboard = 0;
                for (current_branch) |inbetween| {
                    o |= inbetween.read(time_slots).bitboard;
                }
                break :blk o;
            };
            const needed_bitboard = (~covered_bitboard) & (@as(ClassBitboard, std.math.maxInt(ClassBitboard)) >> @intCast(options.class_limit - restrictions.classes.len));
            assert(@popCount(needed_bitboard) == remaining_classes);

            const needed: TimeSlot = .{ .bitboard = needed_bitboard };

            if (needed.hasMandatoryOverlap(restrictions)) continue;

            const inbetweens = try gpa.alloc(Inbetween, current_branch.len + 1);
            errdefer gpa.free(inbetweens);
            @memcpy(inbetweens[0..current_branch.len], current_branch);
            inbetweens[current_branch.len] = .{ .time_slot = needed };

            progress_tested.increaseEstimatedTotalItems(1);
            try inbetweenss.append(gpa, inbetweens);
        } else {
            const min = current_branch[current_branch.len - 1].idx; // Haven't tested all that much if this might stop it from finding some possibilities, if it does, `ed5f` was the last commit without this.
            progress_tested.increaseEstimatedTotalItems(time_slots.len - min);
            for (min..time_slots.len) |idx| {
                const inbetweens = try gpa.alloc(Inbetween, current_branch.len + 1);
                errdefer gpa.free(inbetweens);
                @memcpy(inbetweens[0..current_branch.len], current_branch);
                inbetweens[current_branch.len] = .{ .idx = idx };
                try inbetweenss.append(gpa, inbetweens);
            }
        }
    }

    return try outp.toOwnedSlice(gpa);
}

pub fn format(plan: Plan, restrictions: Restrictions, w: *Writer) Writer.Error!void {
    // Create an FBAs to circumvent having to pass a gpa.
    // With default settings, this is gonna be around
    // 5184 bytes extra on the stack for the time slots
    // and 3328 for the suggested layout (8512 in total).
    var ts_buffer: [options.class_limit * (@sizeOf(ClassId) + @sizeOf(Restrictions.Class))]u8 = undefined;
    var ts_buffer_allocator = std.heap.FixedBufferAllocator.init(&ts_buffer);
    const ts_arena = ts_buffer_allocator.allocator();

    var layout_buffer: [options.teacher_limit * @sizeOf(Restrictions.Class.TeacherId) + 3 * options.class_limit * @sizeOf([]Restrictions.Class.TeacherId)]u8 = undefined;
    var layout_buffer_allocator = std.heap.FixedBufferAllocator.init(&layout_buffer);
    const layout_arena = layout_buffer_allocator.allocator();

    for (plan.time_slots, 0..) |ts, ts_id| {
        try w.print("{d}:\n", .{ts_id});

        ts_buffer_allocator.reset();
        const ts_class_ids = ts.classes(ts_arena) catch |err| switch (err) {
            error.OutOfMemory => unreachable,
        };
        const ts_classes = ts_arena.alloc(Restrictions.Class, ts_class_ids.len) catch |err| switch (err) {
            error.OutOfMemory => unreachable,
        };
        for (ts_class_ids, ts_classes) |id, *class| {
            class.* = restrictions.classes[id];
        }

        layout_buffer_allocator.reset();
        const layout = Restrictions.Class.suggestLayout(ts_classes, layout_arena) catch |err| switch (err) {
            error.OutOfMemory => unreachable,
        };
        assert(ts_classes.len == layout.len);

        for (ts_classes, layout) |class, teacher_ids| {
            try w.print("  {s}:", .{class.name});
            for (teacher_ids.mandatory) |id| {
                try w.print(" {s}", .{restrictions.teacher_table[id]});
            }
            for (teacher_ids.optional) |id| {
                try w.print(" {s}", .{restrictions.teacher_table[id]});
            }
            for (teacher_ids.maybe) |id| {
                try w.print(" ({s})", .{restrictions.teacher_table[id]});
            }
            try w.print("\n", .{});
        }
    }
}
