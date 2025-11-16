//! Anything allocated in this structure is saved
//! by the arena allocator passed to `fromInput`.
//!
//! Asserts amount of teacher <= `options.teacher_limit`

const std = @import("std");
const options = @import("options");

const Input = @import("Input.zig");

const Allocator = std.mem.Allocator;

const Restrictions = @This();

/// Amount of conferences that can happen
/// concurrently at any one time.
room_count: u16,
time_slots: u16,

/// Teacher lists do not contain entries
/// from the input's `not_available`.
classes: []const Class,

teacher_table: []const []const u8,

pub const TeacherBitboard = std.meta.Int(.unsigned, options.teacher_limit);
pub const TeacherId = std.math.Log2Int(TeacherBitboard);
pub const Class = struct {
    name: []const u8,
    /// TODO: Maybe remove this if it doesn't prove necessary.
    mandatory: []const TeacherId,
    optional: []const TeacherId,
    mandatory_bitboard: TeacherBitboard,
};

pub fn fromInput(gpa: Allocator, arena: Allocator, input: Input) Allocator.Error!Restrictions {
    var teacher_table: std.StringHashMapUnmanaged(TeacherId) = .empty;
    defer teacher_table.deinit(gpa);
    var teacher_i: TeacherId = 0;

    for (input.not_available) |t_inp| {
        if (teacher_table.get(t_inp)) |_| {
            @branchHint(.unlikely); // Considering this is first and we expect the user to not do duplicates, this is quite unlikely.
        } else {
            // TODO: We might not even have to add them to the table.
            try teacher_table.put(gpa, t_inp, teacher_i);
            teacher_i += 1;
        }
    }
    // Any id below this is in `not_available`.
    const not_available_cutoff = teacher_i;

    const classes = try arena.alloc(Class, input.classes.len);
    for (input.classes, classes) |class_inp, *class_out| {
        class_out.name = try arena.dupe(u8, class_inp.name);

        class_out.mandatory_bitboard = 0;
        const mandatory = try arena.alloc(TeacherId, class_inp.mandatory.len);
        for (class_inp.mandatory, mandatory) |t_inp, *t_out| {
            if (teacher_table.get(t_inp)) |id| {
                if (id >= not_available_cutoff) {
                    t_out.* = id;
                    class_out.mandatory_bitboard |= @shlExact(@as(TeacherBitboard, 1), id);
                }
            } else {
                t_out.* = teacher_i;
                class_out.mandatory_bitboard |= @shlExact(@as(TeacherBitboard, 1), teacher_i);
                try teacher_table.put(gpa, t_inp, teacher_i);
                teacher_i += 1;
            }
        }
        class_out.mandatory = mandatory;

        const optional = try arena.alloc(TeacherId, class_inp.optional.len);
        for (class_inp.optional, optional) |t_inp, *t_out| {
            if (teacher_table.get(t_inp)) |id| {
                if (id >= not_available_cutoff) t_out.* = id;
            } else {
                t_out.* = teacher_i;
                try teacher_table.put(gpa, t_inp, teacher_i);
                teacher_i += 1;
            }
        }
        class_out.optional = optional;
    }

    const array_teacher_table = try arena.alloc([]const u8, teacher_i);
    var teacher_table_iterator = teacher_table.iterator();
    while (teacher_table_iterator.next()) |entry| {
        array_teacher_table[entry.value_ptr.*] = try arena.dupe(u8, entry.key_ptr.*);
    }

    return .{
        .room_count = input.room_count,
        .time_slots = input.time_slots,
        .classes = classes,
        .teacher_table = array_teacher_table,
    };
}
