const std = @import("std");

const Instruction = @import("lowerer.zig").Instruction;

pub const Inliner = struct {
    executable_instructions: std.ArrayList(Instruction),
    files: std.StringHashMap(usize),

    ty_defs: TypeDef,

    pub const TypeDef = union(enum) {
        struct_def: StructDef,

        pub const StructDef = struct {
            
        };
    };
};
