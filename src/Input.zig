const std = @import("std");
const zon = std.zon;

const Allocator = std.mem.Allocator;

const Input = @This();

/// Amount of conferences that can happen
/// concurrently at any one time.
room_count: u16,
time_slots: u16,

/// Teachers to be ignored in search.
not_available: []const TeacherId,
classes: []const Class,

pub const Class = struct {
    name: []const u8,
    mandatory: []const TeacherId,
    optional: []const TeacherId,
};
pub const TeacherId = []const u8;

pub fn fromFile(gpa: Allocator, path: []const u8, stdout: *std.Io.Writer) !Input {
    const file_contents: [:0]const u8 = blk: {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();

        var file_buffer: [256]u8 = undefined;
        var file_reader = file.reader(&file_buffer);
        const reader = &file_reader.interface;

        if (file_reader.size) |size| { // Allocate right amount if we know the size.
            const contents = try gpa.allocSentinel(u8, @intCast(size), 0);
            errdefer gpa.free(contents);
            reader.readSliceAll(contents) catch |err| switch (err) {
                error.EndOfStream => unreachable,
                else => return err,
            };
            break :blk contents;
        } else { // Otherwise, do two allocations 3:
            const contents_no_sentinel = try reader.allocRemaining(gpa, .unlimited);
            defer gpa.free(contents_no_sentinel);
            const contents = try gpa.dupeZ(u8, contents_no_sentinel);
            errdefer gpa.free(contents);
            break :blk contents;
        }
    };
    defer gpa.free(file_contents);

    var zon_diagnostics: zon.parse.Diagnostics = .{};
    defer zon_diagnostics.deinit(gpa);
    const input = zon.parse.fromSlice(Input, gpa, file_contents, &zon_diagnostics, .{}) catch |err| switch (err) {
        error.ParseZon => {
            try stdout.print("Error: Parsing INPUT failed\n\n", .{});
            try zon_diagnostics.format(stdout);
            try stdout.flush();
            return err;
        },
        else => return err,
    };
    errdefer input.deinit(gpa);

    return input;
}
/// Deinitialize an input read from a file.
pub fn deinit(input: Input, gpa: Allocator) void {
    zon.parse.free(gpa, input);
}
