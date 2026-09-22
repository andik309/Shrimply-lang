const std = @import("std");
const shpl = @import("shpl");

pub fn main(init: std.process.Init) !void {
    errdefer |err| if (err == std.mem.Allocator.Error.OutOfMemory) std.debug.print("buy more ram lol\n", .{});

    _ = &init;
    
    const code =
        // \\ .,:;
        // \\
        // \\ ({[)}]
        // \\
        // \\ += -= *= /= %=
        // \\ // |= &= ^=
        // \\ <<= >>=
        // \\ ||= &&= ^^=
        // \\ + - * / %
        // \\ | & ^
        // \\ << >>
        // \\ || && ^^
        // \\ == !=
        // \\ <= >=
        // \\ < >
        // \\ .* .? .!
        // \\ ~ !
        // \\ =
        // \\
        // \\ let muu #subst @min @"let" "str" 'char' 52
        // \\ 67+67+677+677 == 1488

        \\let foo = func() void {};
        \\
        \\let @"main" = func() void {
        \\    let muu: usize = 0;
        \\    muu = 6;
        \\};
    ;

    _ = &code;

    // const file_tokens = try shpl.lexer.lexFile(code, "<unknown>", init.gpa, false);
    // defer init.gpa.free(file_tokens);

    // const file_node, var arena = try shpl.parser.parseFile(code, file_tokens, "<unknown>", init.gpa);
    // defer _ = arena.reset(.free_all);

    // const file_ir = try shpl.lowerer.lowerFile(file_node, init.gpa);
    // defer {
    //     for (file_ir) |instruction| instruction.deinit(init.gpa);
    //     init.gpa.free(file_ir);
    // }

    // for (file_ir, 0..) |instruction, i| {
    //     std.debug.print("{:0>4} : {any}\n", .{ i, instruction });
    // }

    // const file_inlined_data = try shpl.inliner.inlineFile(code, "<unknown>", init.gpa);

    // _ = file_inlined_data;
}
