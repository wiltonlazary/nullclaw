const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const isPathSafe = @import("path_security.zig").isPathSafe;
const isResolvedPathAllowed = @import("path_security.zig").isResolvedPathAllowed;

/// Default maximum file size to read (10MB).
const DEFAULT_MAX_FILE_SIZE: u64 = 10 * 1024 * 1024;

/// Common binary file signatures (magic numbers)
const BinarySignatures = struct {
    const png = "\x89PNG";
    const jpg = "\xFF\xD8\xFF";
    const gif = "GIF87a";
    const gif89 = "GIF89a";
    const pdf = "%PDF";
    const zip = "PK\x03\x04";
    const rar = "Rar!";
    const sevenz = "7z\xBC\xAF\x27\x1C";
    const exe_mz = "MZ";
    const elf = "\x7FELF";
    const mp4_ftyp = "ftyp";
    const webp = "RIFF";
};

fn isBinaryContent(data: []const u8) bool {
    if (data.len < 4) return false;

    // Check magic numbers
    if (std.mem.startsWith(u8, data, BinarySignatures.png)) return true;
    if (std.mem.startsWith(u8, data, BinarySignatures.jpg)) return true;
    if (std.mem.startsWith(u8, data, BinarySignatures.gif)) return true;
    if (std.mem.startsWith(u8, data, BinarySignatures.gif89)) return true;
    if (std.mem.startsWith(u8, data, BinarySignatures.pdf)) return true;
    if (std.mem.startsWith(u8, data, BinarySignatures.zip)) return true;
    if (std.mem.startsWith(u8, data, BinarySignatures.rar)) return true;
    if (std.mem.startsWith(u8, data, BinarySignatures.sevenz)) return true;
    if (std.mem.startsWith(u8, data, BinarySignatures.exe_mz)) return true;
    if (std.mem.startsWith(u8, data, BinarySignatures.elf)) return true;
    if (std.mem.startsWith(u8, data, BinarySignatures.webp)) return true;

    // MP4: check for "ftyp" at offset 4
    if (data.len > 8 and std.mem.indexOf(u8, data[4..12], BinarySignatures.mp4_ftyp) != null) return true;

    // Check for null bytes in first 8KB (common binary indicator)
    const check_len = @min(data.len, 8192);
    for (data[0..check_len]) |byte| {
        if (byte == 0) return true;
    }

    return false;
}

fn getBinaryFileType(data: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, data, BinarySignatures.png)) return "PNG image";
    if (std.mem.startsWith(u8, data, BinarySignatures.jpg)) return "JPEG image";
    if (std.mem.startsWith(u8, data, BinarySignatures.gif)) return "GIF image";
    if (std.mem.startsWith(u8, data, BinarySignatures.gif89)) return "GIF image";
    if (std.mem.startsWith(u8, data, BinarySignatures.pdf)) return "PDF document";
    if (std.mem.startsWith(u8, data, BinarySignatures.zip)) return "ZIP archive";
    if (std.mem.startsWith(u8, data, BinarySignatures.rar)) return "RAR archive";
    if (std.mem.startsWith(u8, data, BinarySignatures.sevenz)) return "7z archive";
    if (std.mem.startsWith(u8, data, BinarySignatures.exe_mz)) return "Windows executable";
    if (std.mem.startsWith(u8, data, BinarySignatures.elf)) return "Linux executable";
    if (std.mem.startsWith(u8, data, BinarySignatures.webp)) return "WebP image";
    if (data.len > 8 and std.mem.indexOf(u8, data[4..12], BinarySignatures.mp4_ftyp) != null) return "MP4 video";

    // Fallback: use extension
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".png")) return "PNG image";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "JPEG image";
    if (std.mem.eql(u8, ext, ".gif")) return "GIF image";
    if (std.mem.eql(u8, ext, ".webp")) return "WebP image";
    if (std.mem.eql(u8, ext, ".pdf")) return "PDF document";
    if (std.mem.eql(u8, ext, ".zip")) return "ZIP archive";
    if (std.mem.eql(u8, ext, ".mp4")) return "MP4 video";
    if (std.mem.eql(u8, ext, ".mp3")) return "MP3 audio";
    if (std.mem.eql(u8, ext, ".wav")) return "WAV audio";

    return "binary file";
}

/// Read file contents with workspace path scoping.
pub const FileReadTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},
    max_file_size: u64 = DEFAULT_MAX_FILE_SIZE,

    pub const tool_name = "file_read";
    pub const tool_description = "Read the contents of a file in the workspace";
    pub const tool_params =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Relative path to the file within the workspace"}},"required":["path"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *FileReadTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *FileReadTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const path = root.getString(args, "path") orelse
            return ToolResult.fail("Missing 'path' parameter");

        // Build full path — absolute or relative
        const full_path = if (std.fs.path.isAbsolute(path)) blk: {
            if (self.allowed_paths.len == 0)
                return ToolResult.fail("Absolute paths not allowed (no allowed_paths configured)");
            if (std.mem.indexOfScalar(u8, path, 0) != null)
                return ToolResult.fail("Path contains null bytes");
            break :blk try allocator.dupe(u8, path);
        } else blk: {
            if (!isPathSafe(path))
                return ToolResult.fail("Path not allowed: contains traversal or absolute path");
            break :blk try std.fs.path.join(allocator, &.{ self.workspace_dir, path });
        };
        defer allocator.free(full_path);

        // Resolve to catch symlink escapes
        const resolved = std.fs.cwd().realpathAlloc(allocator, full_path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to resolve file path: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(resolved);

        // Validate against workspace + allowed_paths + system blocklist
        const ws_resolved: ?[]const u8 = std.fs.cwd().realpathAlloc(allocator, self.workspace_dir) catch null;
        defer if (ws_resolved) |wr| allocator.free(wr);

        if (!isResolvedPathAllowed(allocator, resolved, ws_resolved orelse "", self.allowed_paths)) {
            return ToolResult.fail("Path is outside allowed areas");
        }

        // Check file size
        const file = std.fs.openFileAbsolute(resolved, .{}) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to open file: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer file.close();

        const stat = try file.stat();
        const max_usize_u64: u64 = @intCast(std.math.maxInt(usize));
        const effective_max_file_size = @min(self.max_file_size, max_usize_u64);
        if (stat.size > effective_max_file_size) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "File too large: {} bytes (limit: {} bytes)",
                .{ stat.size, effective_max_file_size },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        // Read contents
        const contents = file.readToEndAlloc(allocator, @intCast(effective_max_file_size)) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to read file: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        // Check if content is binary
        if (isBinaryContent(contents)) {
            const file_type = getBinaryFileType(contents, path);
            const msg = try std.fmt.allocPrint(
                allocator,
                "[Binary file detected: {s}, size: {d} bytes. Use [IMAGE:path] marker for images, or appropriate tool for other binary files.]",
                .{ file_type, contents.len },
            );
            allocator.free(contents);
            return ToolResult{ .success = true, .output = msg };
        }

        return ToolResult{ .success = true, .output = contents };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "file_read tool name" {
    var ft = FileReadTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    try std.testing.expectEqualStrings("file_read", t.name());
}

test "file_read tool schema has path" {
    var ft = FileReadTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "path") != null);
}

test "file_read reads existing file" {
    // Create temp dir and file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "test.txt", .data = "hello world" });

    // Get the real path of the tmp dir
    const ws_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_path);

    var ft = FileReadTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"test.txt\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("hello world", result.output);
}

test "file_read nonexistent file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const ws_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_path);

    var ft = FileReadTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"nope.txt\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "file_read blocks path traversal" {
    var ft = FileReadTool{ .workspace_dir = "/tmp/workspace" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"../../../etc/passwd\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // error_msg is a static string from ToolResult.fail(), don't free it
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not allowed") != null);
}

test "file_read blocks absolute path" {
    var ft = FileReadTool{ .workspace_dir = "/tmp/workspace" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"/etc/passwd\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // error_msg is a static string from ToolResult.fail(), don't free it
    try std.testing.expect(!result.success);
}

test "file_read missing path param" {
    var ft = FileReadTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // error_msg is a static string from ToolResult.fail(), don't free it
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "file_read nested path" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("sub/dir");
    try tmp_dir.dir.writeFile(.{ .sub_path = "sub/dir/deep.txt", .data = "deep content" });

    const ws_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_path);

    var ft = FileReadTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"sub/dir/deep.txt\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("deep content", result.output);
}

test "file_read empty file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "empty.txt", .data = "" });

    const ws_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_path);

    var ft = FileReadTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"empty.txt\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("", result.output);
}

test "isPathSafe blocks null bytes" {
    try std.testing.expect(!isPathSafe("file\x00.txt"));
}

test "isPathSafe allows relative" {
    try std.testing.expect(isPathSafe("file.txt"));
    try std.testing.expect(isPathSafe("src/main.zig"));
}

test "file_read absolute path without allowed_paths is rejected" {
    var ft = FileReadTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"/tmp/foo.txt\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Absolute paths not allowed") != null);
}

test "file_read absolute path with allowed_paths works" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "hello.txt", .data = "allowed content" });

    const ws_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_path);
    const abs_file = try std.fs.path.join(std.testing.allocator, &.{ ws_path, "hello.txt" });
    defer std.testing.allocator.free(abs_file);

    // JSON-escape backslashes in the path (needed on Windows where paths use \)
    var escaped_buf: [1024]u8 = undefined;
    var esc_len: usize = 0;
    for (abs_file) |c| {
        if (c == '\\') {
            escaped_buf[esc_len] = '\\';
            esc_len += 1;
        }
        escaped_buf[esc_len] = c;
        esc_len += 1;
    }

    var args_buf: [2048]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"path\": \"{s}\"}}", .{escaped_buf[0..esc_len]});
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();

    var ft = FileReadTool{ .workspace_dir = "/nonexistent", .allowed_paths = &.{ws_path} };
    const result = try ft.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("allowed content", result.output);
}
