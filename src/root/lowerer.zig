const std = @import("std");

const Span = @import("utils.zig").Span;

pub const Instruction = union(enum) {
    get: Get,
    int: Int,

    struct_def: StructDef,
    func_def: FuncDef,

    decl: Decl,
    assign: Assign,

    block: Block,

    copy: Copy,

    // macro_inline: MacroInline,
    // inlined_decl: InlinedDecl,

    pub const Get = struct {
        identifier: []const u8,
    };
    pub const Int = struct {
        content: []const u8,
    };

    pub const StructDef = struct {
        fields: []Field,
        decls: []Decl,

        pub const Field = struct {
            name: []const u8,
            ty: Span,
        };
    };
    pub const FuncDef = struct {
        params: []Param,
        ret_ty: Span,
        body: Span,

        pub const Param = struct {
            name: []const u8,
            type: Span,
        };
    };

    pub const Decl = struct {
        name: []const u8,
        ty: ?Span,
        value: Span,
    };
    pub const Assign = struct {
        target: usize,
        value: Span,
    };

    pub const Block = struct {
        body: Span,
    };

    pub const Copy = struct {
        index: usize,
    };

    // pub fn clone(self: Instruction, allocator: std.mem.Allocator) Instruction {}

    pub fn deinit(self: Instruction, allocator: std.mem.Allocator) void {
        switch (self) {
            .get => |d| {
                allocator.free(d.identifier);
            },
            .int => |d| {
                allocator.free(d.content);
            },

            .struct_def => |d| {
                for (d.fields) |field| allocator.free(field.name);
                allocator.free(d.fields);
                for (d.decls) |decl| allocator.free(decl.name);
                allocator.free(d.decls);
            },
            .func_def => |d| {
                for (d.params) |param| allocator.free(param.name);
                allocator.free(d.params);
            },

            .decl => |d| {
                allocator.free(d.name);
            },
            .assign => |d| {
                _ = d;
            },

            .block => |d| {
                _ = d;
            },

            .copy => |d| {
                _ = d;
            },
        }
    }
};

pub const Lowerer = struct {
    instructions: std.ArrayList(Instruction) = .empty,
    gpa: std.mem.Allocator,

    fn lower(self: *Lowerer, node: *const @import("parser.zig").ASTNode) anyerror!Span {
        var value_pos: usize = undefined;

        const span_start = self.instructions.items.len;

        switch (node.tag) {
            .identifier => |d| {
                value_pos = self.instructions.items.len;
                try self.instructions.append(self.gpa, .{ .get = .{ .identifier = try self.gpa.dupe(u8, d) } });
            },
            // .string => {},
            // .char => {},
            .int => |d| {
                value_pos = self.instructions.items.len;
                try self.instructions.append(self.gpa, .{ .int = .{ .content = try self.gpa.dupe(u8, d) } });
            },

            // add: Add,
            // sub: Sub,
            // mul: Mul,
            // div: Div,

            .decl => |d| {
                var result: Instruction.Decl = undefined;

                value_pos = self.instructions.items.len;
                try self.instructions.append(self.gpa, undefined);

                result.name = try self.gpa.dupe(u8, d.name);
                result.ty = if (d.ty) |ty| try self.lower(ty) else null;
                result.value = try self.lower(d.value);

                self.instructions.items[value_pos] = .{ .decl = result };
            },
            .assign => |d| {
                var result: Instruction.Assign = undefined;

                result.target = (try self.lower(d.target)).end-1;

                value_pos = self.instructions.items.len;
                try self.instructions.append(self.gpa, undefined);

                result.value = try self.lower(d.value);

                self.instructions.items[value_pos] = .{ .assign = result };
            },
            // .ret => {},

            .block => |d| {
                var result: Instruction.Block = undefined;

                value_pos = self.instructions.items.len;
                try self.instructions.append(self.gpa, undefined);

                result.body.start = self.instructions.items.len;
                for (d.body) |*inner_node| _ = (try self.lower(inner_node)).end-1;
                result.body.end = self.instructions.items.len;

                self.instructions.items[value_pos] = .{ .block = result };
            },

            .field => unreachable,
            .struct_def => |d| {
                if (d.fields.len != 0) std.debug.panic("todo: implement field lowering", .{});

                var result: Instruction.StructDef = undefined;

                value_pos = self.instructions.items.len;
                try self.instructions.append(self.gpa, undefined);

                result.fields = try self.gpa.alloc(Instruction.StructDef.Field, d.fields.len);
                result.decls = try self.gpa.alloc(Instruction.Decl, d.decls.len);

                for (d.decls, result.decls) |decl, *out| {
                    out.name = try self.gpa.dupe(u8, decl.tag.decl.name);
                    out.ty = if (decl.tag.decl.ty) |ty| try self.lower(ty) else null;
                    out.value = try self.lower(decl.tag.decl.value);
                }

                self.instructions.items[value_pos] = .{ .struct_def = result };
            },
            .func_def => |d| {
                if (d.params.len != 0) std.debug.panic("todo: implement params lowering", .{});

                var result: Instruction.FuncDef = undefined;

                value_pos = self.instructions.items.len;
                try self.instructions.append(self.gpa, undefined);

                result.params = try self.gpa.alloc(Instruction.FuncDef.Param, d.params.len);

                result.ret_ty = try self.lower(d.ret_ty);
                result.body = try self.lower(d.body);

                self.instructions.items[value_pos] = .{ .func_def = result };
            },

            else => |_, tag| std.debug.panic("node {s} cant be lowered now, its not implemented", .{@tagName(tag)}),
        }

        if (value_pos != self.instructions.items.len-1) try self.instructions.append(self.gpa, .{ .copy = .{ .index = value_pos } });

        const span_end = self.instructions.items.len;

        return .{ .start = span_start, .end = span_end };
    }
};

pub fn lowerFile(file_node: *const @import("parser.zig").ASTNode, gpa: std.mem.Allocator) ![]const Instruction {
    var lowerer: Lowerer = .{
        .gpa = gpa,
    };

    _ = try lowerer.lower(file_node);

    return try lowerer.instructions.toOwnedSlice(lowerer.gpa);
}
