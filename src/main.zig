const std = @import("std");
const shpl = @import("shpl");

pub fn main(init: std.process.Init) !void {
    errdefer |err| if (err == std.mem.Allocator.Error.OutOfMemory) std.debug.print("buy more ram lol\n", .{});

    // const code =
    //     // \\ .,:;
    //     // \\
    //     // \\ ({[)}]
    //     // \\
    //     // \\ += -= *= /= %=
    //     // \\ // |= &= ^=
    //     // \\ <<= >>=
    //     // \\ ||= &&= ^^=
    //     // \\ + - * / %
    //     // \\ | & ^
    //     // \\ << >>
    //     // \\ || && ^^
    //     // \\ == !=
    //     // \\ <= >=
    //     // \\ < >
    //     // \\ .* .? .!
    //     // \\ ~ !
    //     // \\ = ::
    //     // \\
    //     // \\ let muu #subst @min @"let" "str" 'char' 52
    //     // \\ 67+67+677+677 == 1488
    //
    //     \\let foo = func() void {};
    //     \\
    //     \\let @"main" = func() void {
    //     \\    let muu: usize = 0;
    //     \\    muu = 6;
    //     \\};
    // ;
    //
    // const file_tokens = try shpl.lexer.lexFile(code, "<unknown>", init.gpa, .only_invalid);
    // defer init.gpa.free(file_tokens);
    //
    // const file_node, var arena = try shpl.parser.parseFile(code, file_tokens, "<unknown>", init.gpa);
    // defer _ = arena.reset(.free_all);
    //
    // const file_ir = try shpl.lowerer.lowerFile(code, "<unknown>", file_node, init.gpa);
    // defer {
    //     for (file_ir) |instruction| std.debug.print("{any}\n", .{ instruction });
    //     init.gpa.free(file_ir);
    // }
    

    const start = std.Io.Clock.now(.real, init.io);

    try shpl.inliner.inlineFile(try std.Io.Dir.cwd().openDir(init.io, "shpl_tests", .{}), init.io, init.gpa, "main.shpl");

    std.debug.print("\n{f}\n", .{ start.untilNow(init.io, .real) });
}
