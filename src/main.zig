const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const CliOptions = @import("CliOptions.zig");
const Input = @import("Input.zig");
const Restrictions = @import("Restrictions.zig");
const Plan = @import("Plan.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

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

    const progress_root = if (!cli_options.quiet) std.Progress.start(.{
        .root_name = "KKP",
        .estimated_total_items = 3, // 1) Parse input
                                    // 2) Combination generation
                                    // 3) Plan generation
        .disable_printing = false,
    }) else null;

    const restrictions: Restrictions = blk: {
        const progress_parse_input = if (progress_root) |progress| progress.start("Parse input", 2) else null;
        defer if (progress_parse_input) |progress| progress.end();

        const input = try Input.fromFile(gpa, cli_options.input, stdout);
        defer input.deinit(gpa);
        if (progress_parse_input) |progress| progress.completeOne();

        const r = try Restrictions.fromInput(gpa, input);
        errdefer r.free(gpa);
        if (progress_parse_input) |progress| progress.completeOne();

        break :blk r;
    };
    defer restrictions.free(gpa);

    if (restrictions.room_count == 0) {
        @branchHint(.cold);
        try stdout.print("Error: Input's room count is 0\n", .{});
        try stdout.flush();
        return error.InvalidInput;
    }
    if (restrictions.time_slots == 0) {
        @branchHint(.cold);
        try stdout.print("Error: Input's time slots is 0\n", .{});
        try stdout.flush();
        return error.InvalidInput;
    }
    if (restrictions.room_count > options.class_limit) {
        @branchHint(.cold);
        try stdout.print("Error: Input's room count ({d}) exceeds class limit ({d})\n", .{ restrictions.room_count, options.class_limit });
        try stdout.flush();
        return error.InvalidInput;
    }
    if (restrictions.classes.len > restrictions.room_count * restrictions.time_slots) {
        @branchHint(.cold);
        try stdout.print("Error: Input's class count ({d}) exceeds maximum possible covered classes ({d} * {d} = {d})\n", .{
            restrictions.classes.len,
            restrictions.room_count,
            restrictions.time_slots,
            restrictions.room_count * restrictions.time_slots,
        });
        try stdout.flush();
        return error.InvalidInput;
    }

    const plans = try restrictions.generatePlans(gpa, progress_root);
    defer {
        for (plans) |plan| {
            gpa.free(plan.time_slots);
        }
        gpa.free(plans);
    }

    if (progress_root) |progress| progress.end();

    if (cli_options.output == null) { // Output to stdout.
        try printPlans(plans, restrictions, stdout);
        try stdout.flush();
    } else if (cli_options.output.?.len > 0) { // Output to file.
        const path = cli_options.output.?;
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var file_buffer: [256]u8 = undefined;
        var file_writer = file.writer(&file_buffer);
        const writer = &file_writer.interface;

        try printPlans(plans, restrictions, stdout);
        try writer.flush();

        try file_writer.end();
    }

    if (!cli_options.quiet) {
        try stdout.print("Found {d} plans.\n", .{plans.len});
        try stdout.flush();
    }
}

fn printPlans(plans: []const Plan, restrictions: Restrictions, w: *Writer) Writer.Error!void {
    for (plans) |plan| {
        try plan.format(restrictions, w);
        try w.print("\n", .{});
    }
}
