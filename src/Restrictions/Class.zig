const std = @import("std");
const options = @import("options");

const Restrictions = @import("../Restrictions.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Class = @This();

pub const TeacherBitboard = std.meta.Int(.unsigned, options.teacher_limit);
pub const TeacherId = std.math.Log2Int(TeacherBitboard);

name: []const u8,
mandatory_bitboard: TeacherBitboard,
optional_bitboard: TeacherBitboard,

/// Writes directly into `outp`.
///
/// Asserts `@popCount(bitboard) == outp.len`.
fn getTeachers(bitboard: TeacherBitboard, outp: []TeacherId) void {
    assert(@popCount(bitboard) == outp.len);
    if (outp.len == 0) return;
    var i: usize = 0;
    for (0..options.teacher_limit) |teacher_id| {
        const mask = @shlExact(@as(TeacherBitboard, 1), @intCast(teacher_id));
        if (bitboard & mask != 0) {
            outp[i] = @intCast(teacher_id);
            i += 1;
            if (i >= outp.len) return;
        }
    }
    unreachable;
}

pub fn intersection(a: Class, b: Class) BitboardResult {
    return .{
        .mandatory = a.mandatory_bitboard & b.mandatory_bitboard,
        .optional = a.optional_bitboard & b.optional_bitboard,
    };
}
pub fn subtract(a: Class, b: Class) BitboardResult {
    return .{
        .mandatory = a.mandatory_bitboard & ~b.mandatory_bitboard,
        .optional = a.optional_bitboard & ~b.optional_bitboard,
    };
}

pub const BitboardResult = struct {
    mandatory: TeacherBitboard,
    optional: TeacherBitboard,
};

/// Returns which class gets which teachers
/// and which teachers can go into either
/// class.
///
/// Asserts the classes don't overlap on
/// mandatory teachers.
/// Asserts `classes.len <= options.class_limit`.
/// Uses at most `options.teacher_limit * @sizeOf(TeacherId) + 3 * options.class_limit * @sizeOf([]TeacherId)`
/// bytes because of that.
pub fn suggestLayout(classes: []const Class, gpa: Allocator) Allocator.Error![]LayoutIds {
    assert(classes.len <= options.class_limit);
    const total_mandatory_bitboard: TeacherBitboard = blk: {
        var r: TeacherBitboard = 0;
        for (classes) |class| {
            assert(r & class.mandatory_bitboard == 0);
            r |= class.mandatory_bitboard;
        }
        break :blk r;
    };

    const idss = try gpa.alloc(LayoutIds, classes.len);
    errdefer gpa.free(idss);
    var idss_done: usize = 0;
    errdefer for (idss[0..idss_done]) |ids| {
        ids.free(gpa);
    };

    while (idss_done < classes.len) : (idss_done += 1) {
        const ids = &idss[idss_done];
        const class = classes[idss_done];

        ids.mandatory = try gpa.alloc(TeacherId, @popCount(class.mandatory_bitboard));
        errdefer gpa.free(ids.mandatory);
        getTeachers(class.mandatory_bitboard, ids.mandatory);

        const optional_bitboard: TeacherBitboard = blk: {
            var r = class.optional_bitboard & ~total_mandatory_bitboard;
            for (classes, 0..) |class_other, i| {
                if (i == idss_done) continue;
                r &= ~class_other.optional_bitboard;
            }
            break :blk r;
        };
        ids.optional = try gpa.alloc(TeacherId, @popCount(optional_bitboard));
        errdefer gpa.free(ids.optional);
        getTeachers(optional_bitboard, ids.optional);

        const maybe_bitboard = class.optional_bitboard & ~optional_bitboard & ~total_mandatory_bitboard;
        ids.maybe = try gpa.alloc(TeacherId, @popCount(maybe_bitboard));
        errdefer gpa.free(ids.maybe);
        getTeachers(maybe_bitboard, ids.maybe);
    }

    return idss;
}

pub const LayoutIds = struct {
    /// All mandatory teachers.
    mandatory: []TeacherId,
    /// Optional teachers that can only partake here.
    optional: []TeacherId,
    /// Teachers that may partake here or elsewhere.
    maybe: []TeacherId,
    pub fn free(ids: LayoutIds, gpa: Allocator) void {
        gpa.free(ids.mandatory);
        gpa.free(ids.optional);
    }
};
