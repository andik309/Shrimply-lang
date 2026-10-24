const std = @import("std");

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const lowerer = @import("lowerer.zig");
const utils = @import("utils.zig");

const Span = utils.Span;
const Instruction = lowerer.Instruction;

// namespaced types - struct, enum, union (can contain StaticDecls)



pub const TypeInfo = union(enum) {
    @"int": Int,

    @"int_literal": void,
    @"type": void,

    @"void": void,
    @"noreturn": void,

    @"struct": Struct,

    @"func": Func,

    pub const Int = struct {
        bits: u16,
        signedness: Signedness,

        pub const Signedness = enum(u1) { signed = 0, unsigned = 1 };


        pub fn fromZigIntType(comptime T: type) Int {
            const info = @typeInfo(T).@"int";

            return .{
                .bits = info.bits,
                .signedness = switch (info.signedness) {
                    .signed => .signed,
                    .unsigned => .unsigned,
                },
            };
        }
    };

    pub const Struct = struct {
        /// pos in Inliner.instructions where it was defined,
        /// its used for `eql` function
        source: usize,

        parent: DeclsParent,
        decls: []StaticDecl,

        // fields: []const Field,

        // pub const Field = struct { name: []const u8, ty: u32 };

        pub fn deinit(self: Struct, allocator: std.mem.Allocator) void {
            for (self.decls) |decl| decl.deinit(allocator);
            allocator.free(self.decls);
        }

        pub fn getDeclByName(self: Struct, name: []const u8) ?StaticDecl {
            for (self.decls) |decl| if (std.mem.eql(u8, decl.name, name)) return decl;
            return null;
        }
    };
    pub const StaticDecl = struct {
        name: []const u8, static_value_index: usize,

        pub fn deinit(self: StaticDecl, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
        }
    };

    pub const Func = struct {
        param_tys: []TypeIndex,
        ret_ty: TypeIndex,

        pub fn deinit(self: Func, allocator: std.mem.Allocator) void {
            allocator.free(self.param_tys);
        }

        pub fn eql(self: Func, other: Func) bool {
            if (self.ret_ty != other.ret_ty) return false;

            if (self.param_tys.len != other.param_tys.len) return false;
            for (self.param_tys, other.param_tys) |self_param_ty, other_param_ty| if (self_param_ty != other_param_ty) return false;

            return true;
        }
    };


    pub fn deinit(self: TypeInfo, allocator: std.mem.Allocator) void {
        switch (self) {
            .@"int" => {},

            .@"int_literal" => {},
            .@"type" => {},

            .@"void" => {},
            .@"noreturn" => {},

            .@"struct" => |d| d.deinit(allocator),

            .@"func" => |d| allocator.free(d.param_tys),
        }
    }
};
/// (MAYBE_RENAME)
pub const DeclsParent = union(enum) {
    /// for imported structs
    none,

    /// index of type in pool
    ty: TypeIndex,

    // ///               struct { `index`, `call index` }
    // subst_macro_call: struct {  usize,      usize    },

    pub fn getDecl(self: DeclsParent, inliner: Inliner, decl_name: []const u8) ?DeclInfo {
        step: switch (self) {
            .none => return null,
            .ty => |d| {
                switch (inliner.pool.get(d)) {
                    .@"struct" => |struct_d| {
                        if (struct_d.getDeclByName(decl_name)) |muu| return .{ .static_value = muu.static_value_index };
                        continue :step struct_d.parent;
                    },
                    else => unreachable,
                }
            },
        }
    }
};
pub const DeclInfo = union(enum) {
    static_value: usize,
};

// maybe i'll switch to it later
pub const TypeIndex = u30;
pub const Type = packed struct(u32) {
    index: TypeIndex,
    modifier: Modifier,

    pub const Modifier = enum(u2) {
        none,

        ref,
        ref_mut,
    };

    pub fn from_index(index: TypeIndex) Type {
        return .{
            .index = index,
            .modifier = .none,
        };
    }

    pub fn from_u32(data: u32) Type {
        return @bitCast(data);
    }

    pub fn to_u32(self: Type) u32 {
        return @bitCast(self);
    }

    pub fn unwrap_to_index(self: Type) !TypeIndex {
        if (self.modifier != .none) return error.UnwrapFailed;
        return self.index;
    }
};



pub const TypePool = struct {
    pool: std.ArrayList(PoolItem),

    pub const indexOfFirstPoolItem: TypeIndex = 131076;

    pub fn deinit(self: *TypePool, allocator: std.mem.Allocator) void {
        for (self.pool.items) |pool_item| {
            switch (pool_item) {
                .@"struct" => |d| { d.deinit(allocator); },
                .@"func"   => |d| { d.deinit(allocator); },
            }
        }
        self.pool.deinit(allocator);
    }

    /// callee owns the result
    pub fn get(self: TypePool, index: TypeIndex) TypeInfo {
        return switch (index) {
            0...65535      => .{ .@"int" = .{ .bits = @truncate(index-0),     .signedness = .signed   } },
            65536...131071 => .{ .@"int" = .{ .bits = @truncate(index-65536), .signedness = .unsigned } },

            131072 => .@"int_literal",

            131073 => .@"type",

            131074 => .@"void",
            131075 => .@"noreturn",

            else => {
                switch (self.pool.items[index-131076]) {
                    .@"struct" => |d| return .{ .@"struct" = d },
                    .@"func" => |d| return .{ .@"func" = d },
                }
            },
        };
    }

    /// callee owns `info`
    pub fn put(self: *TypePool, info: TypeInfo, gpa: std.mem.Allocator) !TypeIndex {
        switch (info) {
            .@"int" => |d| return @as(TypeIndex, @intFromEnum(d.signedness))*65536 + @as(TypeIndex, d.bits),

            .@"int_literal" => return 131072,

            .@"type" => return 131073,

            .@"void" => return 131074,
            .@"noreturn" => return 131075,

            .@"struct" => |d| {
                for (self.pool.items, 131076..) |pool_type_info, i| {
                    if (pool_type_info == .@"struct" and d.source == pool_type_info.@"struct".source) {
                        d.deinit(gpa);
                        return @truncate(i);
                    }
                }

                const result = self.pool.items.len+131076;

                try self.pool.append(gpa, .{ .@"struct" = d });
                return @truncate(result);
            },

            .@"func" => |d| {
                for (self.pool.items, 131076..) |pool_type_info, i| {
                    if (pool_type_info == .@"func" and
                        d.ret_ty == pool_type_info.@"func".ret_ty
                        and std.mem.eql(TypeIndex, d.param_tys, pool_type_info.@"func".param_tys)
                    ) {
                        d.deinit(gpa);
                        return @truncate(i);
                    }
                }

                const result = self.pool.items.len+131076;

                try self.pool.append(gpa, .{ .@"func" = d });
                return @truncate(result);
            }
        }
    }

    /// works only on TypeInfos that dont require pool to exist
    pub fn getStatic(info: TypeInfo) TypeIndex {
        return switch (info) {
            .@"int" => |d| return @as(TypeIndex, @intFromEnum(d.signedness))*65536 + @as(TypeIndex, d.bits),

            .@"int_literal" => return 131072,

            .@"type" => return 131073,

            .@"void" => return 131074,
            .@"noreturn" => return 131075,

            inline else => |_, tag| {
                if (@inComptime()) {
                    @compileError("TypeInfo " ++ @tagName(tag) ++ " requires pool to exist");
                } else {
                    std.debug.panic("TypeInfo {s} requires pool to exist", .{ @tagName(tag) });
                }
            },
        };
    }


    pub const PoolItem = union(enum) {
        @"struct": TypeInfo.Struct,
        @"func": TypeInfo.Func,
    };
};
pub const Inliner = struct {
    cwd: std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,

    pool: TypePool = .{ .pool = .empty },
    cached_files: std.ArrayList(struct { file_path: []const u8, file_code: [:0]const u8, type_index: TypeIndex, span: Span }) = .empty,

    static_values: std.ArrayList(StaticValue) = .empty,
    func_defs: std.ArrayList(FuncDef) = .empty,
    // subst_macroses: 0,

    instructions: std.ArrayList(Instruction) = .empty,
    instructions__source_locs: std.ArrayList(InstructionsSourceLoc) = .empty,

    instructions__label_infos: std.AutoHashMap(usize, LabelInfo),

    inst_infos: std.AutoHashMap(usize, InstInfo),


    /// bridge beetwen inliner and restricter stages + caching previously computed things in inliner (~)  (MAYBE_RENAME)
    pub const InstInfo = union(enum) {
        known_value: ValueContainer,
        known_ty: Type,

        pub fn deinit(self: InstInfo, allocator: std.mem.Allocator) void {
            switch (self) {
                .known_value => |d| {
                    d.deinitFull(allocator);
                },
                .known_ty => {},
            }
        }
    };


    pub const InstructionsSourceLoc = struct {
        instructions: Span,
        file_index: usize,
    };

    pub const LabelInfo = struct {
        name: []const u8,

        breaks_at: std.ArrayList(usize),
        // continues_at: std.ArrayList(usize),

        pub fn deinit(self: *LabelInfo, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            self.breaks_at.deinit(allocator);
        }
    };

    pub const StaticValue = struct{
        parent_ty: TypeIndex,
        value: Value,

        pub const Value = union(enum) {
            unevaluated: struct { ty: ?Span, value: Span },
            evaluated: ValueContainer,
        };

        pub fn deinit(self: StaticValue, allocator: std.mem.Allocator) void {
            switch (self.value) {
                .unevaluated => {},
                .evaluated => |d| d.deinitFull(allocator),
            }
        }
    };

    pub const FuncDef = struct {
        params: []Param,
        ret_ty: TypeIndex,
        body: Span,

        parent: DeclsParent,

        checked: bool = false,

        pub const Param = struct { name: []const u8, ty: TypeIndex };


        pub fn deinit(self: FuncDef, allocator: std.mem.Allocator) void {
            for (self.params) |param| {
                allocator.free(param.name);
            }
            allocator.free(self.params);
        }

        pub fn getTypeInfo(self: FuncDef, allocator: std.mem.Allocator) !TypeInfo {
            const result: TypeInfo.Func = .{
                .param_tys = try allocator.alloc(TypeIndex, self.params.len),
                .ret_ty = self.ret_ty,
            };

            for (self.params, result.param_tys) |param, *out| {
                out.* = param.ty;
            }

            return .{ .@"func" = result };
        }


    };


    pub fn deinit(self: *Inliner) void {
        self.cwd.close(self.io);


        for (self.instructions.items) |instruction| {
            instruction.tag.deinit(self.gpa);
        }
        self.instructions.deinit(self.gpa);

        self.instructions__source_locs.deinit(self.gpa);


        for (self.cached_files.items) |cached_file| {
            self.gpa.free(cached_file.file_code);
            self.gpa.free(cached_file.file_path);
        }
        self.cached_files.deinit(self.gpa);


        self.pool.deinit(self.gpa);


        for (self.static_values.items) |static_value| {
            static_value.deinit(self.gpa);
        }
        self.static_values.deinit(self.gpa);


        for (self.func_defs.items) |func_def| {
            func_def.deinit(self.gpa);
        }
        self.func_defs.deinit(self.gpa);
    }

    pub fn getFileIndexByInstructionIndex(self: *Inliner, instruction_index: usize) error{ InstructionIndexIsNotRegistered }!usize {
        for (self.instructions__source_locs.items) |source_loc| {
            if (source_loc.instructions.start <= instruction_index and instruction_index < source_loc.instructions.end) return source_loc.file_index;
        }

        return error.InstructionIndexIsNotRegistered;
    }
};
pub const InlineTimeInterpretator = struct {
    inliner: *Inliner,
    jobs: std.ArrayList(*Job) = .empty,


    pub const Job = struct {
        parent: ?*Job,
        values: std.ArrayList(ValueContainer) = .empty,
        specific: JobSpecific,


        pub fn deinit(self: *Job, allocator: std.mem.Allocator) void {
            for (self.values.items) |value| value.deinitFull(allocator);
            self.values.deinit(allocator);

            self.specific.deinit(allocator);
        }

        pub fn step(self: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
            return try self.specific.step(self, it_interpretator);
        }
    };

    pub const JobSpecific = union(enum) {
        start: Start,

        compute: Compute,
        compute_ty: ComputeType,
        drop: Drop,

        get_member: GetMember,
        get_static_value: GetStaticValue, // long jump

        ty_check_func_body: TypeCheckFuncBody, // long jump
        ty_check_func_body_obj: TypeCheckFuncBodyObj,
        
        remove_ref_opt: RemoveRefOpt,

        size_of: SizeOf,

        import: Import, // long jump

        // resolve_field_tys: ResolveFieldTypes, // long jump


        pub const Start = struct {
            pub fn step(self: *Start, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
                _ = &self;

                const result = job.values.pop().?;
                it_interpretator.popJob();

                return result;
            }
        };

        pub const Compute = struct {
            index: usize,
            state: State = .start,

            pub const State = enum {
                start,
                asking_for_values,
                computing,
                returning_result,
            };

            pub fn step(self: *Compute, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
                const gpa = it_interpretator.inliner.gpa;
                const instruction = it_interpretator.inliner.instructions.items[self.index];

                if (self.state == .start) {

                    if (it_interpretator.inliner.inst_infos.get(self.index)) |inst_info| switch (inst_info) {
                        .known_value => |value| {
                            try job.parent.?.values.append(gpa, try value.clone(gpa));
                            it_interpretator.popJob();
                        },
                        .known_ty => {
                            self.state = .asking_for_values;
                        },
                    } else {
                        self.state = .asking_for_values;
                    }

                } if (self.state == .returning_result) {

                    const result = job.values.pop().?;


                    const entry = try it_interpretator.inliner.inst_infos.getOrPut(self.index);
                    entry.value_ptr.deinit(gpa);
                    entry.value_ptr.* = .{ .known_value = try result.clone(gpa) };


                    try job.parent.?.values.append(gpa, result);

                    it_interpretator.popJob();

                } else switch (instruction.tag) {
                    .struct_def => |d| switch (self.state) {
                        .asking_for_values => self.state = .computing,
                        .computing => {
                            if (d.fields.len != 0) try utils.todoAsError();

                            const result: TypeInfo.Struct = .{
                                .source = self.index,

                                .decls = try gpa.alloc(TypeInfo.StaticDecl, d.decls.len),
                                .parent = .none,
                            };

                            for (d.decls, result.decls) |decl, *out| {
                                out.name = try gpa.dupe(u8, decl.name);

                                out.static_value_index = it_interpretator.inliner.static_values.items.len;
                                try it_interpretator.inliner.static_values.append(gpa, .{ .parent_ty = undefined, .value = .{ .unevaluated = .{
                                    .ty = decl.ty,
                                    .value = decl.value,
                                } } });
                            }

                            const type_index = try it_interpretator.inliner.pool.put(.{ .@"struct" = result }, gpa);

                            for (it_interpretator.inliner.pool.pool.items[type_index-TypePool.indexOfFirstPoolItem].@"struct".decls) |decl| {
                                it_interpretator.inliner.static_values.items[decl.static_value_index].parent_ty = type_index;
                            }


                            try job.values.append(gpa, try .fromType(.from_index(type_index), gpa));
                            self.state = .returning_result;
                        },
                        else => unreachable,
                    },

                    .func_def => |d| switch (self.state) {
                        .asking_for_values => {
                            for (d.params) |param_d| {
                                _ = try it_interpretator.appendJob(.{
                                    .parent = job,
                                    .specific = .{ .compute = .{
                                        .index = param_d.ty.start,
                                    } },
                                });
                            }

                            _ = try it_interpretator.appendJob(.{
                                .parent = job,
                                .specific = .{ .compute = .{
                                    .index = d.ret_ty.start,
                                } },
                            });

                            self.state = .computing;
                        },
                        .computing => {
                            var result: Inliner.FuncDef = .{
                                .params = try gpa.alloc(Inliner.FuncDef.Param, d.params.len),
                                .ret_ty = undefined,

                                .parent = it_interpretator.getDeclsParent(job),

                                .body = d.body,
                            };

                            for (d.params, result.params) |param, *out| {
                                out.name = try gpa.dupe(u8, param.name);
                                out.ty = (try job.values.pop().?.toTypeDeinitFull(gpa)).index; // TODO checks
                            }
                            result.ret_ty = try (try job.values.pop().?.toTypeDeinitFull(gpa)).unwrap_to_index(); // TODO checks

                            const result_index: u32 = @truncate(it_interpretator.inliner.func_defs.items.len);
                            try it_interpretator.inliner.func_defs.append(gpa, result);

                            const result_ty_index: u30 = try it_interpretator.inliner.pool.put(try result.getTypeInfo(gpa), gpa);


                            try job.values.append(gpa, (try ValueContainer.fromInt(u32, result_index, gpa)).withTy(.from_index(result_ty_index)));
                            self.state = .returning_result;
                        },
                        else => unreachable,
                    },

                    .identifier => |d| switch (self.state) {
                        .asking_for_values => {
                            if (std.mem.eql(u8, d, "void")) {
                                try job.values.append(gpa, try .fromType(.from_index(comptime TypePool.getStatic(.@"void")), gpa));
                            } else if (it_interpretator.getDeclsParent(job).getDecl(it_interpretator.inliner.*, d)) |decl| {
                                _ = try it_interpretator.appendJob(.{
                                    .parent = job,
                                    .specific = .{ .get_static_value = .{
                                        .index = decl.static_value
                                    } }
                                });
                            } else {
                                const file_index = try it_interpretator.inliner.getFileIndexByInstructionIndex(self.index);

                                const file_code = it_interpretator.inliner.cached_files.items[file_index].file_code;
                                const file_path = it_interpretator.inliner.cached_files.items[file_index].file_path;

                                const code_span = instruction.loc;

                                utils.highlightCode(file_code, file_path, code_span, "error: use of undeclarated identifier `{f}`", .{ std.fmt.Alt([]const u8, utils.formatRawString){ .data = d } });
                                return error.UseOfUndeclaratedIdentifier;
                            }

                            self.state = .computing;
                        },
                        .computing => self.state = .returning_result,
                        else => unreachable,
                    },

                    inline else => |_, tag| {
                        std.debug.print("todo: {s}\n", .{ @tagName(tag) });
                        try utils.todoAsError();
                    },
                }

                return null;
            }
        };
        pub const ComputeType = struct {
            index: usize,

            state: State = .start,

            pub const State = enum {
                start,

                stage0,
                stage1,

                returning_value,
            };

            pub fn step(self: *ComputeType, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
                const gpa = it_interpretator.inliner.gpa;
                const instruction = it_interpretator.inliner.instructions.items[self.index];

                switch (instruction.tag) {
                    .struct_def => switch (self.state) {
                        .start => {
                            self.state = .stage0;
                        },

                        .stage0 => {
                            _ = try it_interpretator.appendJob(.{
                                .parent = job,
                                .specific = .{ .compute = .{
                                    .index = self.index,
                                } },
                            });

                            self.state = .returning_value;
                        },

                        .returning_value => {
                            const type_index = job.values.pop().?.toTypeDeinitFull(gpa) catch unreachable;
                            _ = &type_index;

                            try job.parent.?.values.append(gpa, try .fromType(.from_index(comptime TypePool.getStatic(.@"type")), gpa));
                            it_interpretator.popJob();
                        },

                        else => unreachable,
                    },

                    // .func_def => {},

                    .block => |instruction_d| switch (self.state) {
                        .start => {
                            self.state = .stage0;
                        },

                        .stage0 => {
                            for (instruction_d.body) |body_part| {
                                _ = try it_interpretator.appendJob(.{
                                    .parent = job,
                                    .specific = .{ .compute_ty = .{
                                        .index = body_part.start,
                                    } },
                                });
                            }

                            self.state = .stage1;
                        },

                        .stage1 => {
                            var is_noreturn = false;

                            for (0..instruction_d.body.len) |i| {
                                _ = &i; // it will be used for warnings/errors like 'unreachable code' (TODO)

                                switch (job.values.pop().?.toTypeDeinitFull(gpa) catch unreachable) {
                                    .from_index(comptime TypePool.getStatic(.@"void")) => {},
                                    .from_index(comptime TypePool.getStatic(.@"noreturn")) => {
                                        is_noreturn = true;
                                    },

                                    else => try utils.todoAsError(),
                                }
                            }

                            if (is_noreturn) {
                                try job.values.append(gpa, try .fromType(.from_index(comptime TypePool.getStatic(.@"noreturn")), gpa));
                            } else {
                                try job.values.append(gpa, try .fromType(.from_index(comptime TypePool.getStatic(.@"void")), gpa));
                            }

                            self.state = .returning_value;
                        },

                        .returning_value => {
                            const type_index = job.values.pop().?.toTypeDeinitFull(gpa) catch unreachable;
                            _ = &type_index;

                            try job.parent.?.values.append(gpa, try .fromType(.from_index(comptime TypePool.getStatic(.@"type")), gpa));
                            it_interpretator.popJob();
                        },
                    },

                    .call => |instruction_d| switch (self.state) {
                        .start => {
                            self.state = .stage0;
                        },

                        .stage0 => {
                            _ = try it_interpretator.appendJob(.{
                                .parent = job,
                                .specific = .{ .compute = .{
                                    .index = instruction_d.callee.start,
                                } },
                            });

                            for (instruction_d.args) |arg| {
                                _ = try it_interpretator.appendJob(.{
                                    .parent = job,
                                    .specific = .{ .compute_ty = .{
                                        .index = arg.start,
                                    } }
                                });
                            }

                            self.state = .stage1;
                        },
                        .stage1 => {
                            const func = job.values.pop().?;
                            std.debug.assert(it_interpretator.inliner.pool.get(func.ty.index) == .@"func");
                            const func_index: u32 = try func.withTy(.from_index(comptime TypePool.getStatic(.{ .@"int" = .fromZigIntType(u32) }))).toIntDeinitFull(u32, gpa);

                            if (it_interpretator.inliner.func_defs.items[func_index].params.len != 0) try utils.todoAsError(); // TODO

                            try job.values.append(gpa, try .fromType(.from_index(it_interpretator.inliner.func_defs.items[func_index].ret_ty), gpa));

                            self.state = .returning_value;
                        },

                        .returning_value => {
                            try job.parent.?.values.append(gpa, job.values.pop().?);
                            it_interpretator.popJob();
                        },
                    },

                    inline else => |_, tag| {
                        std.debug.print("todo: {s}\n", .{ @tagName(tag) });
                        try utils.todoAsError();
                    },
                }

                return null;
            }
        };
        pub const Drop = struct {
            pub fn step(self: *Drop, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
                _ = self;
                _ = job;

                it_interpretator.popJob();

                return null;
            }
        };

        pub const GetMember = struct {
            member: []const u8,

            state: State = .start,

            pub const State = enum {
                start,

                checking_ty_of_operand,

                type__computing_member,

                returning_result,
            };

            pub fn step(self: *GetMember, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
                const gpa = it_interpretator.inliner.gpa;

                switch (self.state) {
                    .start => {
                        if (job.values.getLast().ty == Type.from_index(comptime TypePool.getStatic(.@"type"))) { // TODO type modificators inheritance
                            self.state = .checking_ty_of_operand;
                        } else {
                            try utils.todoAsError();
                        }
                    },

                    .checking_ty_of_operand => {
                        self.state = .type__computing_member;
                    },

                    .type__computing_member => {
                        const index = try (try job.values.pop().?.toTypeDeinitFull(gpa)).unwrap_to_index(); // TODO type modificators inheritance
                        const ty = it_interpretator.inliner.pool.get(index);

                        const d: TypeInfo.Struct = switch (ty) {
                            .@"struct" => |d| d,
                            else => { try utils.todoAsError(); unreachable; },
                        };

                        const static_value_index = (d.getDeclByName(self.member) orelse return error.NoSuchDecl).static_value_index;

                        _ = try it_interpretator.appendJob(.{
                            .parent = job,
                            .specific = .{ .get_static_value = .{
                                .index = static_value_index,
                            } },
                        });

                        self.state = .returning_result;
                    },

                    .returning_result => {
                        try job.parent.?.values.append(gpa, job.values.pop().?);
                        it_interpretator.popJob();
                    },
                }

                return null;
            }
        };
        pub const GetStaticValue = struct {
            index: usize,

            state: State = .start,

            pub const State = union(enum) {
                start,
                checking_if_evaluated,
                // computing_type,
                computing_value,
                // coercing_value,
                saving_value,
                returning_value,
            };


            pub fn step(self: *GetStaticValue, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
                _ = &self;
                _ = &job;
                _ = &it_interpretator;

                const gpa = it_interpretator.inliner.gpa;

                switch (self.state) {
                    .start => {
                        self.state = .checking_if_evaluated;
                    },
                    .checking_if_evaluated => {
                        switch (it_interpretator.inliner.static_values.items[self.index].value) {
                            .evaluated => |value| {
                                self.state = .returning_value;
                                try job.values.append(gpa, try value.clone(gpa));
                            },
                            .unevaluated => {
                                self.state = .computing_value;
                            },
                        }
                    },
                    // .computing_type,
                    .computing_value => {
                        _ = try it_interpretator.appendJob(.{ .parent = job, .specific = .{ .compute = .{
                            .index = it_interpretator.inliner.static_values.items[self.index].value.unevaluated.value.start,
                        } } });

                        self.state = .saving_value;
                    },
                    // .coercing_value,
                    .saving_value => {
                        it_interpretator.inliner.static_values.items[self.index].value = .{ .evaluated = try job.values.getLast().clone(gpa) };

                        self.state = .returning_value;
                    },
                    .returning_value => {
                        try job.parent.?.values.append(gpa, job.values.pop().?);
                        it_interpretator.popJob();
                    },
                }

                return null;
            }
        };

        pub const TypeCheckFuncBody = struct {
            state: State = .start,
            func_index: u32,

            pub const State = union(enum) {
                start,
                checking_if_not_checked,
                returning_result,
            };

            pub fn step(self: *TypeCheckFuncBody, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
                _ = &job;
                _ = &it_interpretator;

                const gpa = it_interpretator.inliner.gpa;

                switch (self.state) {
                    .start => {
                        self.state = .checking_if_not_checked;
                        if (it_interpretator.inliner.func_defs.items[self.func_index].checked) {}
                    },
                    .checking_if_not_checked => {
                        const value = job.values.getLast();
                        std.debug.assert(it_interpretator.inliner.pool.get(value.ty.index) == .@"func");

                        self.func_index = try value.withTy(.from_index(comptime TypePool.getStatic(.{ .@"int" = .fromZigIntType(u32) }))).toInt(u32); // TODO type modifiers inheritance

                        const job1 = try it_interpretator.appendJob(.{
                            .parent = job,
                            .specific = .{ .drop = .{} },
                        });

                        _ = try it_interpretator.appendJob(.{
                            .parent = job1,
                            .specific = .{ .compute_ty = .{
                                .index = it_interpretator.inliner.func_defs.items[self.func_index].body.start,
                            } },
                        });

                        it_interpretator.inliner.func_defs.items[self.func_index].checked = true;

                        self.state = .returning_result;
                    },
                    .returning_result => {
                        try job.parent.?.values.append(gpa, job.values.pop().?);
                        it_interpretator.popJob();
                    },
                }

                return null;
            }
        };
        pub const TypeCheckFuncBodyObj = struct {
            state: State = .start,

            pub const State = union(enum) {
                start,
                stage0,
                stage1,
                returning_result,
            };

            pub fn step(self: *TypeCheckFuncBody, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
                _ = &job;
                _ = &it_interpretator;

                switch (self.state) {
                    .start => {
                        const value = job.values.getLast();
                        std.debug.assert(it_interpretator.inliner.pool.get(value.ty.index) == .@"func");
                        
                        self.state = .stage0;
                    },
                    .stage0 => {
                        self.state = .stage1;

                        it_interpretator.appendJob(.{ 
                            .parent = job,
                            .specific = .{ .remove_ref_opt = .{} },
                        });
                    },
                    .stage1 => {
                        const value = job.values.pop();
                        std.debug.assert(value.ty.modifier == .none);

                        const func_index = try value.withTy(.from_index(comptime TypePool.getStatic(.{ .@"int" = .fromZigIntType(u32) }))).toInt(u32); // TODO type modifiers inheritance

                        it_interpretator.appendJob(.{ 
                            .parent = job,
                            .specific = .{ .ty_check_func_body = .{
                                .func_index = func_index,
                            } },
                        });

                        self.state = .returning_result;
                    },
                    .returning_result => {
                        it_interpretator.popJob();
                    },
                }

                return null;
            }
        };

        pub const RemoveRefOpt = struct {
            state: State = .start,

            pub const State = enum {
                start,
                stage0,
                returning_result,
            };

            pub fn step(self: *RemoveRefOpt, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
                _ = &job;
                _ = &it_interpretator;

                const gpa = it_interpretator.inliner.gpa;

                switch (self.state) {
                    .start => {
                        if (job.values.getLast().ty.modifier != .none) {
                            self.state = .returning_result;
                        } else {
                            self.state = .stage0;
                        }
                    },
                    .stage0 => {
                        self.state = .returning_result;
                        const ty_index = job.values.getLast().ty.index;
                        
                        _ = try it_interpretator.appendJob(.{
                            .parent = job,
                            .specific = .{ .size_of = .{
                                .ty_index = ty_index,
                            } },
                        });
                    },
                    .stage1 => {
                        const len = job.values.pop().?.toBigIntDeinitFull(gpa);
                        const ty_index = job.values.getLast().ty.index;
                        const ptr: [*]u8 = @ptrFromInt(try job.values.pop().?.withTy(.from_index(comptime TypePool.getStatic(.{ .@"int" = .fromZigIntType(usize) }))).toIntDeinitFull(usize, gpa));

                        const result = ValueContainer{
                            .data = ptr[0..len],
                            .ty = .from_index(ty_index),
                        };

                        try job.values.append(gpa, result);
                    },
                    .returning_result => {
                        try job.parent.?.values.append(gpa, job.values.pop().?);
                        it_interpretator.popJob();
                    },
                }

                return null;
            }
        };

        pub const SizeOf = struct { // TODO SizeOf
            ty_index: TypeIndex,

            pub fn step(self: *SizeOf, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
                const type_info = it_interpretator.inliner.pool.get(self.ty_index);

                const gpa = it_interpretator.inliner.gpa;

                const size = switch (type_info) {
                    .@"int" => unreachable,
                
                    .@"int_literal" => unreachable,
                    .@"type" => unreachable,
                
                    .@"void" => unreachable,
                    .@"noreturn" => unreachable,
                
                    .@"struct" => unreachable,
                
                    .@"func" => unreachable,
                };

                // try job.parent.?.values.append(gpa, .fromBigInt(value: Managed, allocator: Allocator));
            }
        };

        pub const Import = struct {
            file_path: []const u8,

            state: State = .start,
            cached_file_index: usize = undefined,

            pub const State = enum {
                start,

                checking_if_cached,

                computing,
                continuing_computing,

                returning,
            };

            pub fn step(self: *Import, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
                const gpa = it_interpretator.inliner.gpa;

                switch (self.state) {
                    .start => {
                        self.state = .checking_if_cached;
                    },

                    .checking_if_cached => {
                        var cached = false;
                        for (it_interpretator.inliner.cached_files.items) |cached_file| {
                            if (std.mem.eql(u8, self.file_path, cached_file.file_path)) {
                                try job.values.append(it_interpretator.inliner.gpa, try .fromType(.from_index(cached_file.type_index), it_interpretator.inliner.gpa));

                                cached = true;
                                self.state = .returning;

                                break;
                            }
                        }

                        if (!cached) {
                            self.state = .computing;
                        }
                    },

                    .computing => {
                        const file_code = try it_interpretator.inliner.cwd.readFileAllocOptions(it_interpretator.inliner.io, self.file_path, it_interpretator.inliner.gpa, .unlimited, .of(u8), 0);
                        errdefer it_interpretator.inliner.gpa.free(file_code);

                        const instructions_span = blk0: {
                            const file_ir = blk1: {
                                const file_tokens = try lexer.lexFile(file_code, self.file_path, it_interpretator.inliner.gpa, .only_invalid);
                                defer it_interpretator.inliner.gpa.free(file_tokens);

                                const file_node, var arena = try parser.parseFile(file_code, file_tokens, self.file_path, it_interpretator.inliner.gpa);
                                defer _ = arena.reset(.free_all);

                                const file_ir = try lowerer.lowerFile(file_code, self.file_path, file_node, it_interpretator.inliner.gpa);

                                break :blk1 file_ir;
                            };
                            errdefer {
                                for (file_ir) |instruction| {
                                    instruction.tag.deinit(it_interpretator.inliner.gpa);
                                }
                                it_interpretator.inliner.gpa.free(file_ir);
                            }

                            for (file_ir) |*instr| instr.tag.shiftMut(it_interpretator.inliner.instructions.items.len, .forward);


                            var instructions_span: Span = .{ .start = it_interpretator.inliner.instructions.items.len, .end = undefined };
                            try it_interpretator.inliner.instructions.appendSlice(it_interpretator.inliner.gpa, file_ir);
                            instructions_span.end = it_interpretator.inliner.instructions.items.len;

                            it_interpretator.inliner.gpa.free(file_ir);


                            break :blk0 instructions_span;
                        };

                        _ = try it_interpretator.appendJob(.{
                            .parent = job,
                            .specific = .{ .compute = .{
                                .index = instructions_span.start,
                            } },
                        });


                        self.cached_file_index = it_interpretator.inliner.cached_files.items.len;
                        try it_interpretator.inliner.cached_files.append(it_interpretator.inliner.gpa, .{
                            .file_path = try it_interpretator.inliner.gpa.dupe(u8, self.file_path),
                            .file_code = file_code,
                            .type_index = undefined,
                            .span = instructions_span,
                        });

                        try it_interpretator.inliner.instructions__source_locs.append(it_interpretator.inliner.gpa, .{
                            .instructions = instructions_span,
                            .file_index = self.cached_file_index,
                        });

                        self.state = .continuing_computing;
                    },

                    .continuing_computing => {
                        it_interpretator.inliner.cached_files.items[self.cached_file_index].type_index = try (try job.values.getLast().toType()).unwrap_to_index();
                        self.state = .returning;
                    },

                    .returning => {
                        try job.parent.?.values.append(gpa, job.values.pop().?);
                        it_interpretator.popJob();
                    },
                }

                return null;
            }
        };

        // pub const ResolveFieldTypes = struct {
        //     
        // };


        pub fn step(self: *JobSpecific, job: *Job, it_interpretator: *InlineTimeInterpretator) !?ValueContainer {
            switch (self.*) { inline else => |*d| {
                return try d.step(job, it_interpretator);
            } }
        }

        pub fn deinit(self: JobSpecific, allocator: std.mem.Allocator) void {
            switch (self) {
                .start => {},

                .compute => {},
                .compute_ty => {},
                .drop => {},

                .get_member => |d| {
                    allocator.free(d.member);
                },
                .get_static_value => {},

                .ty_check_func_body => {},

                .import => |d| {
                    allocator.free(d.file_path);
                },
            }
        }
    };


    pub fn deinit(self: *InlineTimeInterpretator) void {
        for (self.jobs.items) |job| self.deinitJob(job);
        self.jobs.deinit(self.inliner.gpa);
    }

    pub fn step(self: *InlineTimeInterpretator) !?ValueContainer {
        return try self.jobs.getLast().step(self);
    }

    /// TODO better neme
    pub fn stepBool(self: *InlineTimeInterpretator, result: *ValueContainer) !bool {
        result.* = (try self.step()) orelse return true;
        return false;
    }



    pub fn popJob(self: *InlineTimeInterpretator) void {
        self.deinitJob(self.jobs.pop().?);
    }

    pub fn appendJob(self: *InlineTimeInterpretator, job: Job) !*Job {
        try self.jobs.append(self.inliner.gpa, try utils.createAndCopy(Job, self.inliner.gpa, job));

        return self.jobs.getLast();
    }


    pub fn deinitJob(self: InlineTimeInterpretator, job: *Job) void {
        job.deinit(self.inliner.gpa);
        self.inliner.gpa.destroy(job);
    }


    pub fn getDeclsParent(self: InlineTimeInterpretator, job: *Job) DeclsParent {
        var curr_job: *Job = job.parent orelse return .none;

        while (true) {
            switch (curr_job.specific) {
                .get_static_value => |d| {
                    return .{ .ty = self.inliner.static_values.items[d.index].parent_ty };
                },
                .ty_check_func_body => |d| {
                    return self.inliner.func_defs.items[d.func_index].parent;
                },
                .import => {
                    return .none;
                },
                else => {}
            }

            if (curr_job.parent) |parent| curr_job = parent
            else return .none;
        }
    }
};

pub const ValueContainer = struct {
    data: []u8, ty: Type,

    pub fn deinit(self: ValueContainer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
    pub fn deinitFull(self: ValueContainer, allocator: std.mem.Allocator) void {
        // TODO   deinitializing of self.data
        allocator.free(self.data);
    }

    pub fn clone(self: ValueContainer, allocator: std.mem.Allocator) !ValueContainer {
        return .{
            .data = try allocator.dupe(u8, self.data),
            .ty = self.ty,
        };
    }


    pub fn fromInt(comptime T: type, value: T, allocator: std.mem.Allocator) !ValueContainer {
        const byte_count = comptime @divExact(@as(usize, @typeInfo(T).int.bits), @as(usize, 8));
        const data = try allocator.alloc(u8, byte_count);

        std.mem.writeInt(T, data[0..byte_count], value, .native);

        return .{
            .data = data,
            .ty = .from_index(comptime TypePool.getStatic(.{ .@"int" = .fromZigIntType(T) })),
        };
    }

    pub fn fromType(value: Type, allocator: std.mem.Allocator) !ValueContainer {
        return (try ValueContainer.fromInt(u32, value.to_u32(), allocator)).withTy(.from_index(comptime TypePool.getStatic(.@"type")));
    }

    /// callee owns `value`
    pub fn fromBigInt(value: std.math.big.int.Managed, allocator: std.mem.Allocator) !ValueContainer {
        const data = try allocator.alloc(u8, @sizeOf(std.math.big.int.Managed));

        @memcpy(
            data,
            @as(  *const [@sizeOf(std.math.big.int.Managed)]u8,  @ptrCast(&value)  ),
        );

        return .{
            .data = data,
            .ty = comptime TypePool.getStatic(.@"int_literal"),
        };
    }


    pub fn toInt(self: ValueContainer, comptime T: type) !T {
        if (self.ty != Type.from_index(comptime TypePool.getStatic(.{ .@"int" = .fromZigIntType(T) }))) return error.MismatchedType;

        const byte_count = comptime (std.math.ceilPowerOfTwo(usize, std.math.divCeil(usize, @typeInfo(T).int.bits, 8) catch unreachable) catch unreachable);

        const result = std.mem.readInt(T, self.data[0..byte_count], .native);

        return result;
    }
    pub fn toIntDeinitFull(self: ValueContainer, comptime T: type, allocator: std.mem.Allocator) !T {
        const result = try self.toInt(T);
        self.deinitFull(allocator);

        return result;
    }

    /// `self` owns the result
    pub fn toBigInt(self: ValueContainer) !std.math.big.int.Managed {
        if (self.ty != comptime TypePool.getStatic(.@"int_literal")) {
            // std.debug.print("expected type 'int_literal', found {}\n", .{ self.ty });
            return error.MismatchedType;
        }
        var result: std.math.big.int.Managed = undefined;

        @memcpy(
            @as(  *[@sizeOf(std.math.big.int.Managed)]u8,  @ptrCast(&result)  ),
            self.data,
        );

        return result;
    }
    pub fn toBigIntDeinitFull(self: ValueContainer, allocator: std.mem.Allocator) !std.math.big.int.Managed {
        const result = (try self.toBigInt()).clone();
        self.deinitFull(allocator);

        return result;
    }

    pub fn toType(self: ValueContainer) !Type {
        if (self.ty != Type.from_index(comptime TypePool.getStatic(.@"type"))) {
            // std.debug.print("expected type 'type', found {}\n", .{ self.ty });
            return error.MismatchedType;
        }


        return .from_u32(try self.withTy(
            .from_index(comptime TypePool.getStatic(.{ .@"int" = .fromZigIntType(u32) }))
        ).toInt(u32));
    }
    pub fn toTypeDeinitFull(self: ValueContainer, allocator: std.mem.Allocator) !Type {
        const result = try self.toType();
        self.deinitFull(allocator);

        return result;
    }


    pub fn withTy(self: ValueContainer, ty: Type) ValueContainer {
        return .{
            .data = self.data,
            .ty = ty,
        };
    }
    pub fn typeOfDeinitFull(self: ValueContainer, allocator: std.mem.Allocator) Type {
        const result = self.ty;
        self.deinitFull(allocator);

        return result;
    }


    pub fn empty(allocator: std.mem.Allocator) !ValueContainer {
        return .{ .data = try allocator.alloc(u8, 0), .ty = comptime TypePool.getStatic(.@"void") };
    }
};



pub fn inlineFile(cwd: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) !void {
    var inliner: Inliner = .{
        .cwd = cwd,
        .io = io,
        .gpa = gpa,

        .instructions__label_infos = .init(gpa),

        .inst_infos = .init(gpa),
    };
    defer inliner.deinit();

    var it_interpretator: InlineTimeInterpretator = .{
        .inliner = &inliner,
    };
    defer it_interpretator.deinit();

    const job0 = try it_interpretator.appendJob(.{
        .parent = null,
        .specific = .{ .start = .{} },
    });
    const job1 = try it_interpretator.appendJob(.{
        .parent = job0,
        .specific = .{ .ty_check_func_body = .{} },
    });
    const job2 = try it_interpretator.appendJob(.{
        .parent = job1,
        .specific = .{ .get_member = .{
            .member = try gpa.dupe(u8, "main"),
        } },
    });
    _ = try it_interpretator.appendJob(.{
        .parent = job2,
        .specific = .{ .import = .{
            .file_path = try gpa.dupe(u8, file_path),
        } },
    });

    var step_count: usize = 0;

    // const main_value: ValueContainer = whl: while (true) {
    //     _ = try it_interpretator.step();
    //     step_count += 1;
    //
    //     if (it_interpretator.jobs.getLast().specific == .start) {
    //         break :whl it_interpretator.jobs.items[it_interpretator.jobs.items.len-1].values.pop().?;
    //     }
    // };
    // defer main_value.deinitFull(gpa);

    var result: ValueContainer = undefined;
    while (try it_interpretator.stepBool(&result)) {
        std.debug.print("{}, {s}\n", .{ it_interpretator.jobs.items.len, @tagName(it_interpretator.jobs.getLast().specific) });
        step_count += 1;
    }
    defer result.deinitFull(gpa);

    std.debug.print("{x} : {any}\n", .{ result.data, inliner.pool.get(result.ty.index) });
    std.debug.print("step count: {}\n", .{ step_count });
}
