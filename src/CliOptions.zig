const std = @import("std");
const options = @import("options");

const CliOptions = @This();

/// Path to input file.
input: []const u8,
/// Path to output file.
/// `null` implies `stdout`.
/// `.len == 0` implies no output.
output: ?[]const u8,

///// Number of concurrent jobs.
//jobs: usize,

/// Whether to print stuff.
/// (doesn't diable errors and program output)
quiet: bool,

/// Slices in returned object only valid
/// as long as `args` is.
pub fn parse(args: []const []const u8, stdout: *std.Io.Writer) ParseError!CliOptions {
    var outp: CliOptions = .{
        .input = undefined,
        .output = null,
//        .jobs = @max(1, std.Thread.getCpuCount() catch 1),
        .quiet = false,
    };
    var input_set = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isArg("-h", "--help", arg)) |_| {
            try stdout.print(help_message, .{args[0]});
            try stdout.flush();
            return error.Help;
        } else if (isArg("-v", "--version", arg)) |_| {
            try stdout.print(version_message, .{options.version});
            try stdout.flush();
            return error.Help;
        } else if (isArg("-o=", "--output=", arg)) |output_start| {
            const output = arg[output_start..];
            if (std.mem.eql(u8, "stdout", output)) {
                outp.output = null;
            } else {
                outp.output = arg[output_start..];
            }
//        } else if (isArg("-j=", "--jobs=", arg)) |jobs_start| {
//            if (jobs_start >= arg.len) {
//                try stdout.print("Error: No number after --jobs.\n", .{});
//                try stdout.flush();
//                return error.ArgTooShort;
//            }
//            const jobs = arg[jobs_start..];
//            outp.jobs = std.fmt.parseInt(usize, jobs, 10) catch |err| switch (err) {
//                error.Overflow => {
//                    try stdout.print("Error: Thread amount '{s}' too big.\n", .{jobs});
//                    try stdout.flush();
//                    return error.ArgJustStraightUpWrong;
//                },
//                error.InvalidCharacter => {
//                    try stdout.print("Error: Thread amount '{s}' contains invalid characters.\n", .{jobs});
//                    try stdout.flush();
//                    return error.ArgJustStraightUpWrong;
//                },
//            };
        } else if (isArg("-q", "--quiet", arg)) |_| {
            outp.quiet = true;
        } else {
            input_set = true;
            outp.input = arg;
        }
    }

    if (!input_set) {
        try stdout.print("Error: No input file specified.\n", .{});
        if (args.len <= 1) try stdout.print("Hint: Run '{s} --help' to get help.", .{args[0]});
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
    \\Copyright (c) Rue04 (iokg04@gmail.com)
    \\Distributed under the MIT License.
    \\
    \\Usage:
    \\ {s} [OPTION]... INPUT
    \\
    \\Options:
    \\ -o=FILE --output=FILE  Write output to FILE, default: stdout.
    \\                        No output will be written if FILE is empty.
  //\\ -j=NUM  --jobs=NUM     Use NUM threads, default: all available.
    \\ -q      --quiet        Do not print to stdout or stderr unnecessarily.
    \\
    \\ -h      --help         Print this help message and exit.
    \\ -v      --version      Print version and copyright information and exit.
    \\
    \\If an option or INPUT is set multiple times, the last one is used.
    \\
;

pub const version_message =
    \\Klassen Konferenz Planer (KKP)
    \\Class Conference Planner (CCP)
    \\
    \\Copyright (c) Rue04 (iokg04@gmail.com)
    \\Distributed under the MIT License.
    \\
    \\Version: {f}
    \\
    \\MIT License
    \\
    \\Copyright (c) Rue04 (iokg04@gmail.com)
    \\
    \\Permission is hereby granted, free of charge, to any person obtaining a copy
    \\of this software and associated documentation files (the "Software"), to deal
    \\in the Software without restriction, including without limitation the rights
    \\to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    \\copies of the Software, and to permit persons to whom the Software is
    \\furnished to do so, subject to the following conditions:
    \\
    \\The above copyright notice and this permission notice shall be included in all
    \\copies or substantial portions of the Software.
    \\
    \\THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    \\IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    \\FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    \\AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    \\LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    \\OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    \\SOFTWARE.
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
