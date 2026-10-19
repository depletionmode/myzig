//! Editor edits a text file: line numbers, wrapping to switch, code
//! indentation, undo and redo, and Ctrl+S to save.
//!
//!     zig build editor -- path/to/file.txt
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

// Small release binaries: MyZig prints panics and log messages.
pub const panic = myzig.panic;
pub const std_options = myzig.std_options;

pub const Editor = struct {
    gpa: std.mem.Allocator,
    doc: ui.TextInput = .{},
    path: ?[]const u8 = null,
    saved: u32 = 0,
    wrap: bool = false,
    numbers: bool = true,
    message: []const u8 = "",

    pub fn deinit(s: *Editor) void {
        s.doc.deinit(s.gpa);
    }

    pub fn open(s: *Editor, path: []const u8) !void {
        const bytes = try myzig.sys.readFile(s.gpa, path, 64 << 20);
        defer s.gpa.free(bytes);
        try s.doc.set(s.gpa, bytes);
        s.doc.caret = 0;
        s.doc.anchor = 0;
        s.path = path;
        s.saved = s.doc.version;
    }

    fn save(s: *Editor) void {
        const path = s.path orelse {
            s.message = "No file to save to: open one with zig build editor -- <path>";
            return;
        };
        myzig.sys.writeFile(path, s.doc.value()) catch {
            s.message = "Could not save";
            return;
        };
        s.saved = s.doc.version;
        s.message = "Saved";
    }

    /// lineCol is where the caret is, from 1.
    pub fn lineCol(s: *const Editor) [2]usize {
        const before = s.doc.value()[0..s.doc.caret];
        const line = std.mem.count(u8, before, "\n") + 1;
        const start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |k| k + 1 else 0;
        const col = std.unicode.utf8CountCodepoints(before[start..]) catch before.len - start;
        return .{ line, col + 1 };
    }
};

const sample =
    \\const std = @import("std");
    \\
    \\pub fn main() !void {
    \\    // Type here: Tab indents, Enter keeps the indentation,
    \\    // Ctrl+Z undoes and Ctrl+Shift+Z redoes.
    \\    std.debug.print("Hello from MyZig\n", .{});
    \\}
    \\
;

pub fn view(s: *Editor, c: *ui.Context) void {
    const t = c.theme;
    c.column(.{ .fill = true, .padding = 12, .gap = 8, .@"align" = .stretch });
    defer c.end();
    {
        c.row(.{ .gap = 12, .@"align" = .center });
        defer c.end();
        const name = if (s.path) |p| std.fs.path.basename(p) else "Untitled";
        const dirty = s.doc.version != s.saved;
        c.textf("{s}{s}", .{ name, if (dirty) " •" else "" }, .{ .bold = true });
        c.spacer();
        _ = c.toggle("Wrap", &s.wrap, .{});
        _ = c.toggle("Line numbers", &s.numbers, .{});
        if (c.button("Save", .{ .primary = true })) s.save();
    }
    if (c.shortcutMods(.s, .{ .ctrl = true })) s.save();
    if (c.textArea(&s.doc, .{ .grow = 1, .wrap = s.wrap, .line_numbers = s.numbers, .code = true, .placeholder = "Empty", .key = "doc" })) s.message = "";
    {
        c.row(.{ .gap = 16 });
        defer c.end();
        const lc = s.lineCol();
        c.textf("Ln {d}, Col {d}", .{ lc[0], lc[1] }, .{ .size = 12, .color = t.text_muted });
        c.textf("{d} lines", .{std.mem.count(u8, s.doc.value(), "\n") + 1}, .{ .size = 12, .color = t.text_muted });
        c.text(s.message, .{ .size = 12, .color = t.text_muted });
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.c_allocator;
    var s = Editor{ .gpa = gpa };
    defer s.deinit();
    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    if (args.next()) |path| {
        s.open(path) catch |err| switch (err) {
            error.FileNotFound => s.path = path, // a new file, saved there
            else => return err,
        };
    } else {
        try s.doc.set(gpa, sample);
        s.saved = s.doc.version;
    }
    try myzig.run(&s, view, .{ .title = "Editor", .width = 760, .height = 520 });
}

const testing = std.testing;

fn harness(s: *Editor, fonts: *myzig.text.Fonts) !myzig.Headless(Editor) {
    var h = try myzig.Headless(Editor).init(testing.allocator, fonts, s, view, 760, 520, 1);
    h.frame();
    return h;
}

test "typing, new lines that keep their indentation, and the arrows" {
    var fonts = try myzig.text.Fonts.init(testing.allocator);
    defer fonts.deinit();
    var s = Editor{ .gpa = testing.allocator };
    defer s.deinit();
    var h = try harness(&s, &fonts);
    defer h.deinit();

    try h.click("Empty");
    h.typeText("fn main() {");
    h.key(.enter);
    h.key(.tab);
    h.typeText("go();");
    h.key(.enter);
    h.typeText("x");
    try testing.expectEqualStrings("fn main() {\n    go();\n    x", s.doc.value());
    // Shift+Tab takes the indentation back.
    h.keyMods(.tab, .{ .shift = true });
    try testing.expectEqualStrings("fn main() {\n    go();\nx", s.doc.value());
    // Up keeps the column; Home and End are the row's.
    h.key(.up);
    try testing.expectEqual([2]usize{ 2, 3 }, s.lineCol());
    h.key(.end);
    h.typeText(" // go");
    try testing.expectEqualStrings("fn main() {\n    go(); // go\nx", s.doc.value());
    h.key(.up);
    h.key(.home);
    h.typeText("pub ");
    try testing.expectEqualStrings("pub fn main() {\n    go(); // go\nx", s.doc.value());
    // Ctrl+End is the end of the text; Backspace in indentation goes back a
    // tab stop.
    h.keyMods(.end, .{ .ctrl = true });
    h.key(.backspace);
    h.key(.enter);
    h.typeText("  ");
    h.typeText("  ");
    h.key(.backspace);
    try testing.expectEqualStrings("pub fn main() {\n    go(); // go\n\n", s.doc.value());
    try testing.expect(h.hasText("4 lines"));
}

test "undo and redo, by words" {
    var fonts = try myzig.text.Fonts.init(testing.allocator);
    defer fonts.deinit();
    var s = Editor{ .gpa = testing.allocator };
    defer s.deinit();
    var h = try harness(&s, &fonts);
    defer h.deinit();

    try h.click("Empty");
    for ("one two") |ch| h.typeText(&.{ch});
    h.key(.enter);
    h.typeText("three");
    h.keyMods(.z, .{ .ctrl = true });
    try testing.expectEqualStrings("one two\n", s.doc.value());
    h.keyMods(.z, .{ .ctrl = true });
    try testing.expectEqualStrings("one two", s.doc.value());
    h.keyMods(.z, .{ .ctrl = true });
    try testing.expectEqualStrings("one ", s.doc.value());
    h.keyMods(.z, .{ .ctrl = true, .shift = true });
    h.keyMods(.y, .{ .ctrl = true });
    try testing.expectEqualStrings("one two\n", s.doc.value());
    // A new edit drops what redo would have put back.
    h.typeText("!");
    h.keyMods(.y, .{ .ctrl = true });
    try testing.expectEqualStrings("one two\n!", s.doc.value());
    // Undo puts back a selection that typing replaced.
    h.keyMods(.a, .{ .ctrl = true });
    h.typeText("z");
    h.keyMods(.z, .{ .ctrl = true });
    try testing.expectEqualStrings("one two\n!", s.doc.value());
    try testing.expectEqual([2]u32{ 0, 9 }, s.doc.selection());
}

test "the pointer: clicks place the caret on their line, drags select across lines" {
    var fonts = try myzig.text.Fonts.init(testing.allocator);
    defer fonts.deinit();
    var s = Editor{ .gpa = testing.allocator };
    defer s.deinit();
    try s.doc.set(testing.allocator, "alpha beta\ngamma delta\nepsilon");
    var h = try harness(&s, &fonts);
    defer h.deinit();

    const r = s.doc.rect;
    const lh = fonts.metrics(.regular, 14).line_height;
    const pad_y: f32 = 8;
    // Past the end of the second line: its end.
    h.clickAt(r.x + r.w - 20, r.y + pad_y + lh * 1.5);
    try testing.expectEqual(@as(u32, 22), s.doc.caret);
    // A drag from the first line to the third selects across.
    h.drag(r.x + r.w - 20, r.y + pad_y + lh * 0.5, r.x + r.w - 20, r.y + pad_y + lh * 2.5);
    try testing.expectEqual([2]u32{ 10, @intCast(s.doc.value().len) }, s.doc.selection());
    // A triple click selects its line, a double click a word.
    h.clickAtN(r.x + 60, r.y + pad_y + lh * 1.5, 3);
    try testing.expectEqual([2]u32{ 11, 22 }, s.doc.selection());
    h.clickAtN(r.x + 60, r.y + pad_y + lh * 2.5, 2);
    try testing.expectEqualStrings("epsilon", s.doc.value()[s.doc.selection()[0]..s.doc.selection()[1]]);
}

test "the wheel scrolls a long text, and the caret keeps in view" {
    var fonts = try myzig.text.Fonts.init(testing.allocator);
    defer fonts.deinit();
    var s = Editor{ .gpa = testing.allocator };
    defer s.deinit();
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..300) |i| try text.print(testing.allocator, "line {d}\n", .{i});
    try s.doc.set(testing.allocator, text.items);
    s.doc.caret = 0;
    s.doc.anchor = 0;
    var h = try harness(&s, &fonts);
    defer h.deinit();

    const r = s.doc.rect;
    h.scroll(r.x + r.w / 2, r.y + r.h / 2, 200);
    try testing.expectEqual(@as(f32, 200), s.doc.view.offset);
    // Ctrl+End scrolls to the caret at the end.
    h.clickAt(r.x + r.w / 2, r.y + 20);
    h.keyMods(.end, .{ .ctrl = true });
    try testing.expectEqual(s.doc.view.maxOffset(), s.doc.view.offset);
    // Page Up goes up a page of rows.
    h.key(.page_up);
    try testing.expect(s.doc.view.offset < s.doc.view.maxOffset());
    try testing.expect(s.lineCol()[0] < 301);
}

test "wrapping breaks long lines into rows, and Down walks them" {
    var fonts = try myzig.text.Fonts.init(testing.allocator);
    defer fonts.deinit();
    var s = Editor{ .gpa = testing.allocator, .wrap = true };
    defer s.deinit();
    const long = comptime blk: {
        const w = "word ";
        var text: [w.len * 60]u8 = undefined;
        for (&text, 0..) |*c, i| c.* = w[i % w.len];
        break :blk text;
    };
    try s.doc.set(testing.allocator, &long);
    s.doc.caret = 0;
    s.doc.anchor = 0;
    var h = try harness(&s, &fonts);
    defer h.deinit();
    h.frame();
    try testing.expect(s.doc.rows.items.len > 1);
    for (s.doc.rows.items) |rw| try testing.expectEqual(@as(u32, 0), rw.line);
    h.clickAt(s.doc.rect.x + 60, s.doc.rect.y + 10);
    h.key(.down);
    try testing.expectEqual(@as(usize, 1), s.lineCol()[0]);
    try testing.expect(s.doc.caret >= s.doc.rows.items[1].start);
    try testing.expect(s.doc.caret < s.doc.rows.items[2].start);
}
