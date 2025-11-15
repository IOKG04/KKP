const std = @import("std");

const CliOptions = @This();

/// Path to input file.
input: []const u8,
/// Path to output file.
/// `null` implies `stdout`.
output: ?[]const u8,

/// Number of concurrent jobs.
jobs: usize,

/// Slices in returned object only valid
/// as long as `args` is.
pub fn parse(args: []const []const u8, stdout: *std.Io.Writer) ParseError!CliOptions {
    var outp: CliOptions = .{
        .input = undefined,
        .output = null,
        .jobs = @max(1, std.Thread.getCpuCount() catch 1),
    };
    var input_set = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isArg("-h", "--help", arg)) |_| {
            try stdout.print(help_message, .{args[0]});
            try stdout.flush();
            return error.Help;
        } else if (isArg("-o=", "--output=", arg)) |output_start| {
            if (output_start >= arg.len) {
                try stdout.print("Error: No path after --output.\n", .{});
                try stdout.flush();
                return error.ArgTooShort;
            }
            outp.output = arg[output_start..];
        } else if (isArg("-j=", "--jobs=", arg)) |jobs_start| {
            if (jobs_start >= arg.len) {
                try stdout.print("Error: No number after --jobs.\n", .{});
                try stdout.flush();
                return error.ArgTooShort;
            }
            const jobs = arg[jobs_start..];
            outp.jobs = std.fmt.parseInt(usize, jobs, 10) catch |err| switch (err) {
                error.Overflow => {
                    try stdout.print("Error: Thread amount '{s}' too big.\n", .{jobs});
                    try stdout.flush();
                    return error.ArgJustStraightUpWrong;
                },
                error.InvalidCharacter => {
                    try stdout.print("Error: Thread amount '{s}' contains invalid characters.\n", .{jobs});
                    try stdout.flush();
                    return error.ArgJustStraightUpWrong;
                },
            };
        } else {
            input_set = true;
            outp.input = arg;
        }
    }

    if (!input_set) {
        try stdout.print("Error: No input file specified.\n", .{});
        try stdout.flush();
        return error.NoInput;
    }

    return outp;
}

pub const ParseError = error {
    /// Not really an error, program should
    /// exit normally if this occurs.
    Help,
    NoInput,
    ArgTooShort,
    ArgJustStraightUpWrong,
} || std.Io.Writer.Error;

pub const help_message =
    \\Klassen Konferenz Planer (KKP)
    \\Class Conference Planner (CCP)
    \\
    \\Usage:
    \\ {s} [OPTION]... INPUT
    \\
    \\Options:
    \\ -o=FILE --output=FILE  Write output to FILE, default: stdout
    \\ -j=NUM  --jobs=NUM     Use NUM threads, default: all available
    \\
    \\If an option or INPUT is set multiple times, the last one is used.
    \\
;

/// Returns `null` if `arg` isn't the one tested for.
/// Otherwise returns length of the specifying part.
fn isArg(comptime short: []const u8, comptime long: []const u8, arg: []const u8) ?usize {
    if (std.mem.startsWith(u8, arg, short)) {
        return short.len;
    } else if (std.mem.startsWith(u8, arg, long)) {
        return long.len;
    } else return null;
}
