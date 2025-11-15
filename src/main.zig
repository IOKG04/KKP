const std = @import("std");
const builtin = @import("builtin");

const CliOptions = @import("CliOptions.zig");

pub fn main() !void {
    const using_smp_allocator = builtin.mode == .ReleaseFast;
    var dbg_allocator = if (using_smp_allocator) {} else std.heap.DebugAllocator(.{}).init;
    defer { if (!using_smp_allocator) _ = dbg_allocator.deinit(); }
    const gpa = if (using_smp_allocator) std.heap.smp_allocator else dbg_allocator.allocator();

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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

    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{
        .allocator = gpa,
        .n_jobs = cli_options.jobs -| 1,
    });
    defer thread_pool.deinit();
}
