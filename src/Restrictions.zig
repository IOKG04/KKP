//! Asserts amount of teacher <= `options.teacher_limit`

const std = @import("std");
const options = @import("options");

const Input = @import("Input.zig");
const Plan = @import("Plan.zig");
const TimeSlot = @import("TimeSlot.zig");

const Allocator = std.mem.Allocator;

const Restrictions = @This();

pub const Class = @import("Restrictions/Class.zig");

/// Amount of conferences that can happen
/// concurrently at any one time.
room_count: u16,
time_slots: u16,

/// Teacher lists do not contain entries
/// from the input's `not_available`.
classes: []const Class,

teacher_table: []const []const u8,

const TeacherBitboard = Class.TeacherBitboard;
const TeacherId = Class.TeacherId;

pub fn fromInput(gpa: Allocator, input: Input) Allocator.Error!Restrictions {
    var teacher_table: std.StringHashMapUnmanaged(TeacherId) = .empty;
    defer teacher_table.deinit(gpa);
    var teacher_i: TeacherId = 0;

    for (input.not_available) |t_inp| {
        if (teacher_table.get(t_inp)) |_| {
            @branchHint(.unlikely); // Considering this is first and we expect the user to not do duplicates, this is quite unlikely.
                                    // TODO: Performance test replacing this with `.cold`.
        } else {
            // TODO: We might not even have to add them to the table.
            try teacher_table.put(gpa, t_inp, teacher_i);
            teacher_i += 1;
        }
    }
    // Any id below this is in `not_available`.
    const not_available_cutoff = teacher_i;

    const classes = try gpa.alloc(Class, input.classes.len);
    errdefer gpa.free(classes);
    var class_names_allocated: usize = 0;
    errdefer {
        for (classes[0..class_names_allocated]) |class| {
            gpa.free(class.name);
        }
    }
    for (input.classes, classes) |class_inp, *class_out| {
        class_out.name = try gpa.dupe(u8, class_inp.name);
        class_names_allocated += 1;

        class_out.mandatory_bitboard = 0;
        for (class_inp.mandatory) |t_inp| {
            if (teacher_table.get(t_inp)) |id| {
                if (id >= not_available_cutoff) {
                    class_out.mandatory_bitboard |= @shlExact(@as(TeacherBitboard, 1), id);
                }
            } else {
                class_out.mandatory_bitboard |= @shlExact(@as(TeacherBitboard, 1), teacher_i);
                try teacher_table.put(gpa, t_inp, teacher_i);
                teacher_i += 1;
            }
        }

        class_out.optional_bitboard = 0;
        for (class_inp.optional) |t_inp| {
            if (teacher_table.get(t_inp)) |id| {
                if (id >= not_available_cutoff) {
                    class_out.optional_bitboard |= @shlExact(@as(TeacherBitboard, 1), id);
                }
            } else {
                class_out.optional_bitboard |= @shlExact(@as(TeacherBitboard, 1), teacher_i);
                try teacher_table.put(gpa, t_inp, teacher_i);
                teacher_i += 1;
            }
        }
    }

    const array_teacher_table = try gpa.alloc([]const u8, teacher_i);
    errdefer gpa.free(array_teacher_table);
    var teacher_names_done: usize = 0;
    errdefer for (array_teacher_table[0..teacher_names_done]) |teacher_name| {
        gpa.free(teacher_name);
    };

    var teacher_table_iterator = teacher_table.iterator();
    while (teacher_table_iterator.next()) |entry| {
        array_teacher_table[entry.value_ptr.*] = try gpa.dupe(u8, entry.key_ptr.*);
        teacher_names_done += 1;
    }

    return .{
        .room_count = input.room_count,
        .time_slots = input.time_slots,
        .classes = classes,
        .teacher_table = array_teacher_table,
    };
}

pub fn free(r: Restrictions, gpa: Allocator) void {
    for (r.teacher_table) |teacher_name| {
        gpa.free(teacher_name);
    }
    gpa.free(r.teacher_table);

    for (r.classes) |class| {
        gpa.free(class.name);
    }
    gpa.free(r.classes);
}

/// Generates all possible plans given `restrictions`.
pub fn generatePlans(restrictions: Restrictions, gpa: Allocator, progress_root: ?std.Progress.Node) Allocator.Error![]Plan {
    const time_slots = try TimeSlot.generateTimeSlots(gpa, restrictions, progress_root);
    defer gpa.free(time_slots);

    const plans = try Plan.generatePlans(gpa, restrictions, time_slots, progress_root);
    errdefer {
        for (plans) |plan| {
            gpa.free(plan.time_slots);
        }
        gpa.free(plans);
    }

    return plans;
}
