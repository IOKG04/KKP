const std = @import("std");

const Plan = @import("../Plan.zig");
const TimeSlot = @import("../TimeSlot.zig");

const Allocator = std.mem.Allocator;

/// Returns `plans` but with all duplicates
/// (only order shuffled) removed.
///
/// The plans themselves have to be freed too!
///
/// TODO: Make multithreaded.
pub fn filter(gpa: Allocator, plans: []const Plan, progress_root: std.Progress.Node) Allocator.Error![]Plan {
    const progress_filter_plans = progress_root.start("Filter generated plans", 0);
    defer progress_filter_plans.end();
    const progress_tested = progress_filter_plans.start("Plans tested", plans.len);
    defer progress_tested.end();
    const progress_valid = progress_filter_plans.start("Non-duplicated plans found", 0);
    defer progress_valid.end();

    var outp = try std.ArrayList(Plan).initCapacity(gpa, 1);
    errdefer {
        for (outp.items) |plan| {
            gpa.free(plan.time_slots);
        }
        outp.deinit(gpa);
    }

    {
        const time_slots = try gpa.dupe(TimeSlot, plans[0].time_slots);
        errdefer gpa.free(time_slots);
        outp.appendAssumeCapacity(.{ .time_slots = time_slots });

        progress_tested.completeOne();
        progress_valid.completeOne();
    }

    inp_loop: for (plans[1..]) |plan_inp| {
        defer progress_tested.completeOne();

        for (outp.items) |plan_no_dupe| {
            if (plan_inp.isShuffle(plan_no_dupe)) continue :inp_loop;
        }

        const time_slots = try gpa.dupe(TimeSlot, plan_inp.time_slots);
        errdefer gpa.free(time_slots);
        try outp.append(gpa, .{ .time_slots = time_slots });
        progress_valid.completeOne();
    }

    return try outp.toOwnedSlice(gpa);
}
