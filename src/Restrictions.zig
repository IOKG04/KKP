//! Anything allocated in this structure is saved
//! by the arena allocator passed to `fromInput`.

const std = @import("std");

const Input = @import("Input.zig");

const Allocator = std.mem.Allocator;

const Restrictions = @This();

/// Amount of conferences that can happen
/// concurrently at any one time.
room_count: u16,
time_slots: u16,

/// Teachers to be ignored in search.
not_available: []const TeacherId,
classes: []const Class,

teacher_table: []const []const u8,

pub const TeacherId = u16;
pub const Class = struct {
    name: []const u8,
    mandatory: []const TeacherId,
    optional: []const TeacherId,
};

pub fn fromInput(gpa: Allocator, arena: Allocator, input: Input) Allocator.Error!Restrictions {
    var teacher_table: std.StringHashMapUnmanaged(TeacherId) = .empty;
    defer teacher_table.deinit(gpa);
    var teacher_i: u16 = 0;

    const not_available = try arena.alloc(TeacherId, input.not_available.len);
    for (input.not_available, not_available) |t_inp, *t_out| {
        if (teacher_table.get(t_inp)) |id| {
            @branchHint(.unlikely); // Considering this is first and we expect the user to not do duplicates, this is quite unlikely.
            t_out.* = id;
        } else {
            t_out.* = teacher_i;
            try teacher_table.put(gpa, t_inp, teacher_i);
            teacher_i += 1;
        }
    }

    const classes = try arena.alloc(Class, input.classes.len);
    for (input.classes, classes) |class_inp, *class_out| {
        class_out.name = try arena.dupe(u8, class_inp.name);

        const mandatory = try arena.alloc(TeacherId, class_inp.mandatory.len);
        for (class_inp.mandatory, mandatory) |t_inp, *t_out| {
            if (teacher_table.get(t_inp)) |id| {
                t_out.* = id;
            } else {
                t_out.* = teacher_i;
                try teacher_table.put(gpa, t_inp, teacher_i);
                teacher_i += 1;
            }
        }
        class_out.mandatory = mandatory;

        const optional = try arena.alloc(TeacherId, class_inp.optional.len);
        for (class_inp.optional, optional) |t_inp, *t_out| {
            if (teacher_table.get(t_inp)) |id| {
                t_out.* = id;
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
        .not_available = not_available,
        .classes = classes,
        .teacher_table = array_teacher_table,
    };
}
