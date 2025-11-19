const std = @import("std");
const builtin = @import("builtin");

const CliOptions = @import("CliOptions.zig");
const Input = @import("Input.zig");
const Restrictions = @import("Restrictions.zig");
const Plan = @import("Plan.zig");
const TimeSlot = @import("TimeSlot.zig");

const Allocator = std.mem.Allocator;

pub fn main() !void {
    const using_dbg_allocator = builtin.mode != .ReleaseFast;
    var dbg_allocator = if (using_dbg_allocator) std.heap.DebugAllocator(.{}).init else {};
    defer { if (using_dbg_allocator) _ = dbg_allocator.deinit(); }
    const gpa = if (using_dbg_allocator) dbg_allocator.allocator() else std.heap.smp_allocator;

    var arena_allocator = std.heap.ArenaAllocator.init(if (using_dbg_allocator) gpa else std.heap.page_allocator); // Default to `page_allocator` cause apparently it's faster (haven't tested myself).
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try std.process.argsAlloc(arena);
    const cli_options = CliOptions.parse(args, stdout) catch |err| switch (err) {
        error.Help => return,
        else => return err,
    };

//    var thread_pool: std.Thread.Pool = undefined;
//    try thread_pool.init(.{
//        .allocator = gpa,
//        .n_jobs = cli_options.jobs -| 1,
//    });
//    defer thread_pool.deinit();

    const progress_root = std.Progress.start(.{
        .root_name = "KKP",
        .estimated_total_items = 4, // 1) Parse input
                                    // 2) Combination generation
                                    // 3) Plan generation
                                    // 4) Plan filtering
        .disable_printing = cli_options.quiet,
    });

    const restrictions: Restrictions = blk: {
        const progress_parse_input = progress_root.start("Parse input", 2);
        defer progress_parse_input.end();

        const input = try Input.fromFile(gpa, cli_options.input, stdout);
        defer input.deinit(gpa);
        progress_parse_input.completeOne();

        const r = try Restrictions.fromInput(gpa, input);
        errdefer r.free(gpa);
        progress_parse_input.completeOne();

        break :blk r;
    };
    defer restrictions.free(gpa);

    const time_slots = try TimeSlot.generateTimeSlots(gpa, restrictions, progress_root);
    defer gpa.free(time_slots);

    const unfiltered_plans = try Plan.generatePlans(gpa, restrictions, time_slots, progress_root);
    defer {
        for (unfiltered_plans) |plan| {
            gpa.free(plan.time_slots);
        }
        gpa.free(unfiltered_plans);
    }

    const filtered_plans = try filterPlans(gpa, unfiltered_plans, progress_root);
    defer {
        for (filtered_plans) |plan| {
            gpa.free(plan.time_slots);
        }
        gpa.free(filtered_plans);
    }

    progress_root.end();

    for (filtered_plans) |plan| {
        for (plan.time_slots) |ts| {
            try stdout.print("{{ ", .{});
            const ts_classes = try ts.classes(gpa);
            defer gpa.free(ts_classes);
            for (ts_classes) |class_id| {
                const class_name = restrictions.classes[class_id].name;
                try stdout.print("{s} ", .{class_name});
            }
            try stdout.print("}}\n", .{});
        }
        try stdout.print("\n", .{});
    }
    try stdout.print("Found {d} plans in total.\n", .{unfiltered_plans.len});
    try stdout.print("Found {d} plans after filtering.\n", .{filtered_plans.len});
    try stdout.flush();
}

/// Returns `plans` but with all duplicates
/// (only order shuffled) removed.
///
/// The plans themselves have to be freed too!
///
/// TODO: Make multithreaded.
/// TODO: Move to some other file probably.
fn filterPlans(gpa: Allocator, plans: []const Plan, progress_root: std.Progress.Node) Allocator.Error![]Plan {
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
