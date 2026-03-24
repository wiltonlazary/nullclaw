//! Knowledge Graph memory — entity-relation store backed by SQLite with recursive CTEs.
//!
//! Schema:
//!   kg_entities   (id TEXT PRIMARY KEY, type TEXT NOT NULL, content TEXT NOT NULL, created_at TEXT NOT NULL)
//!   kg_relations  (id TEXT PRIMARY KEY, subject_id TEXT NOT NULL, predicate TEXT NOT NULL, object_id TEXT NOT NULL, created_at TEXT NOT NULL)
//!   kg_entities_fts (FTS5 virtual table on kg_entities.content)
//!
//! Graph traversal via recursive CTE:
//!   WITH RECURSIVE traversal(id, depth) AS (
//!       SELECT id, 0 FROM kg_entities WHERE id = ?1
//!       UNION ALL
//!       SELECT r.object_id, t.depth + 1 FROM kg_relations r, traversal t
//!        WHERE r.subject_id = t.id AND t.depth < ?2
//!   ) SELECT e.* FROM kg_entities e, traversal t WHERE e.id = t.id;
//!
//! Recall query encoding:
//!   "kg:traverse:{entity_id}:{max_depth}"  — BFS graph traversal from entity
//!   "kg:path:{from}:{to}:{max_depth}"     — find path between two entities
//!   "kg:relations:{entity_id}"             — all edges for an entity
//!   plain text                             — FTS5 search on entity content

const std = @import("std");
const root = @import("../root.zig");
const Memory = root.Memory;
const MemoryCategory = root.MemoryCategory;
const MemoryEntry = root.MemoryEntry;
const log = std.log.scoped(.memory_kg);

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SQLITE_STATIC: c.sqlite3_destructor_type = null;
pub const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const BUSY_TIMEOUT_MS: c_int = 5000;

pub const KgMemory = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,
    owns_self: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db_path: [*:0]const u8) !Self {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }
        if (db) |d| {
            _ = c.sqlite3_busy_timeout(d, BUSY_TIMEOUT_MS);
        }

        var self_ = Self{ .db = db, .allocator = allocator };
        try self_.configurePragmas();
        try self_.migrate();
        return self_;
    }

    pub fn deinit(self: *Self) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    fn configurePragmas(self: *Self) !void {
        const pragmas = [_][:0]const u8{
            "PRAGMA journal_mode = DELETE;",
            "PRAGMA synchronous  = NORMAL;",
            "PRAGMA temp_store   = MEMORY;",
            "PRAGMA cache_size   = -2000;",
        };
        for (pragmas) |pragma| {
            var err_msg: [*c]u8 = null;
            const rc = c.sqlite3_exec(self.db, pragma, null, null, &err_msg);
            if (rc != c.SQLITE_OK) {
                log.warn("kg pragma failed: {s}", .{if (err_msg) |m| std.mem.span(m) else "unknown"});
                if (err_msg) |msg| c.sqlite3_free(msg);
            }
        }
    }

    fn migrate(self: *Self) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS kg_entities (
            \\  id         TEXT PRIMARY KEY,
            \\  type       TEXT NOT NULL DEFAULT 'entity',
            \\  content    TEXT NOT NULL,
            \\  created_at TEXT NOT NULL
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS kg_relations (
            \\  id         TEXT PRIMARY KEY,
            \\  subject_id TEXT NOT NULL,
            \\  predicate  TEXT NOT NULL,
            \\  object_id  TEXT NOT NULL,
            \\  created_at TEXT NOT NULL
            \\);
            \\
            \\CREATE INDEX IF NOT EXISTS idx_kg_relations_subject ON kg_relations(subject_id);
            \\CREATE INDEX IF NOT EXISTS idx_kg_relations_object  ON kg_relations(object_id);
            \\CREATE INDEX IF NOT EXISTS idx_kg_relations_predicate ON kg_relations(predicate);
            \\
            \\CREATE VIRTUAL TABLE IF NOT EXISTS kg_entities_fts USING fts5(id, content);
        ;
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                log.err("kg migration failed: {s}", .{std.mem.span(msg)});
                c.sqlite3_free(msg);
            }
            return error.MigrationFailed;
        }
    }

    fn getNowTimestamp(allocator: std.mem.Allocator) ![]u8 {
        const ts = std.time.timestamp();
        return std.fmt.allocPrint(allocator, "{d}", .{ts});
    }

    fn generateId(allocator: std.mem.Allocator) ![]u8 {
        const ts = std.time.nanoTimestamp();
        var buf: [16]u8 = undefined;
        std.crypto.random.bytes(&buf);
        const rand_hi = std.mem.readInt(u64, buf[0..8], .little);
        const rand_lo = std.mem.readInt(u64, buf[8..16], .little);
        return std.fmt.allocPrint(allocator, "{d}-{x}-{x}", .{ ts, rand_hi, rand_lo });
    }

    // ── Graph operations ──────────────────────────────────────────────

    fn storeEntity(self: *Self, id: []const u8, entity_type: []const u8, content: []const u8) !void {
        const now = try getNowTimestamp(self.allocator);
        defer self.allocator.free(now);

        const sql = "INSERT INTO kg_entities (id, type, content, created_at) VALUES (?1, ?2, ?3, ?4) " ++
            "ON CONFLICT(id) DO UPDATE SET content = excluded.content, type = excluded.type";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        // SQLITE_TRANSIENT for now: freed before finalize
        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, entity_type.ptr, @intCast(entity_type.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, content.ptr, @intCast(content.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, now.ptr, @intCast(now.len), SQLITE_TRANSIENT);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.StepFailed;

        // Insert into FTS table directly (app is sole writer)
        {
            const fts_sql = "INSERT OR REPLACE INTO kg_entities_fts (id, content) VALUES (?1, ?2)";
            var fts_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, fts_sql, -1, &fts_stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(fts_stmt);
                _ = c.sqlite3_bind_text(fts_stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
                _ = c.sqlite3_bind_text(fts_stmt, 2, content.ptr, @intCast(content.len), SQLITE_STATIC);
                _ = c.sqlite3_step(fts_stmt);
            }
        }
    }

    fn storeRelation(self: *Self, id: []const u8, subject_id: []const u8, predicate: []const u8, object_id: []const u8) !void {
        const now = try getNowTimestamp(self.allocator);
        defer self.allocator.free(now);

        const sql = "INSERT INTO kg_relations (id, subject_id, predicate, object_id, created_at) VALUES (?1, ?2, ?3, ?4, ?5) " ++
            "ON CONFLICT(id) DO UPDATE SET predicate = excluded.predicate";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 2, subject_id.ptr, @intCast(subject_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, predicate.ptr, @intCast(predicate.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, object_id.ptr, @intCast(object_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 5, now.ptr, @intCast(now.len), SQLITE_TRANSIENT);

        rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_DONE) return error.StepFailed;
    }

    /// BFS traversal from start_id up to max_depth hops, capped by limit.
    fn traverse(self: *Self, allocator: std.mem.Allocator, start_id: []const u8, max_depth: usize, limit: usize) ![]MemoryEntry {
        var entries: std.ArrayListUnmanaged(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        const sql =
            \\WITH RECURSIVE traversal(id, depth) AS (
            \\  SELECT id, 0 FROM kg_entities WHERE id = ?1
            \\  UNION ALL
            \\  SELECT r.object_id, t.depth + 1 FROM kg_relations r, traversal t
            \\   WHERE r.subject_id = t.id AND t.depth < ?2
            \\)
            \\SELECT e.id, e.type, e.content, e.created_at FROM kg_entities e, traversal t WHERE e.id = t.id LIMIT ?3
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, start_id.ptr, @intCast(start_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(max_depth));
        _ = c.sqlite3_bind_int64(stmt, 3, @intCast(if (limit > 0) limit else 100));

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const entry = try self.readEntityFromRow(stmt.?, allocator);
            try entries.append(allocator, entry);
        }

        return entries.toOwnedSlice(allocator);
    }

    /// BFS path finding from from_id to to_id up to max_depth, capped by limit.
    /// Returns entities along the path.
    fn findPath(self: *Self, allocator: std.mem.Allocator, from_id: []const u8, to_id: []const u8, max_depth: usize, limit: usize) ![]MemoryEntry {
        var entries: std.ArrayListUnmanaged(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        const sql =
            \\WITH RECURSIVE path(visited, id, depth) AS (
            \\  SELECT '<' || ?1, ?1, 0
            \\  UNION ALL
            \\  SELECT p.visited || '<' || r.object_id, r.object_id, p.depth + 1
            \\   FROM kg_relations r, path p
            \\   WHERE r.subject_id = p.id AND p.depth < ?3
            \\     AND INSTR(p.visited, '<' || r.object_id) = 0
            \\)
            \\SELECT DISTINCT e.id, e.type, e.content, e.created_at
            \\FROM kg_entities e, path p
            \\WHERE e.id = p.id
            \\ORDER BY p.depth ASC
            \\LIMIT ?4
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, from_id.ptr, @intCast(from_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, to_id.ptr, @intCast(to_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 3, @intCast(max_depth));
        _ = c.sqlite3_bind_int64(stmt, 4, @intCast(if (limit > 0) limit else 100));

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const entry = try self.readEntityFromRow(stmt.?, allocator);
            try entries.append(allocator, entry);
        }

        return entries.toOwnedSlice(allocator);
    }

    /// All relations (incoming + outgoing) for an entity.
    fn getRelations(self: *Self, allocator: std.mem.Allocator, entity_id: []const u8) ![]MemoryEntry {
        var entries: std.ArrayListUnmanaged(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        const sql =
            \\SELECT r.id, r.subject_id, r.predicate, r.object_id, r.created_at
            \\FROM kg_relations r
            \\WHERE r.subject_id = ?1 OR r.object_id = ?1
            \\ORDER BY r.created_at DESC
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, entity_id.ptr, @intCast(entity_id.len), SQLITE_STATIC);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_ptr = c.sqlite3_column_text(stmt, 0);
            const subject_ptr = c.sqlite3_column_text(stmt, 1);
            const predicate_ptr = c.sqlite3_column_text(stmt, 2);
            const object_ptr = c.sqlite3_column_text(stmt, 3);
            const created_ptr = c.sqlite3_column_text(stmt, 4);

            if (id_ptr == null or subject_ptr == null or predicate_ptr == null or object_ptr == null or created_ptr == null) continue;

            const id = try allocator.dupe(u8, std.mem.span(id_ptr));
            errdefer allocator.free(id);

            const content = try std.fmt.allocPrint(allocator, "{s} --{s}--> {s}", .{
                std.mem.span(subject_ptr),
                std.mem.span(predicate_ptr),
                std.mem.span(object_ptr),
            });
            errdefer allocator.free(content);

            const created_at = try allocator.dupe(u8, std.mem.span(created_ptr));
            errdefer allocator.free(created_at);

            const cat_str = try allocator.dupe(u8, "relation");
            errdefer allocator.free(cat_str);

            const key = try allocator.dupe(u8, id);
            errdefer allocator.free(key);

            try entries.append(allocator, MemoryEntry{
                .id = id,
                .key = key,
                .content = content,
                .category = .{ .custom = cat_str },
                .timestamp = created_at,
            });
        }

        return entries.toOwnedSlice(allocator);
    }

    /// FTS5 search on entity content.
    fn ftsSearch(self: *Self, allocator: std.mem.Allocator, query: []const u8, limit: usize) ![]MemoryEntry {
        var entries: std.ArrayListUnmanaged(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        const sql =
            \\SELECT e.id, e.type, e.content, e.created_at
            \\FROM kg_entities e
            \\JOIN kg_entities_fts f ON e.id = f.id
            \\WHERE kg_entities_fts MATCH ?1
            \\ORDER BY bm25(kg_entities_fts) ASC
            \\LIMIT ?2
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, query.ptr, @intCast(query.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(limit));

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const entry = try self.readEntityFromRow(stmt.?, allocator);
            try entries.append(allocator, entry);
        }

        return entries.toOwnedSlice(allocator);
    }

    fn readEntityFromRow(_: *Self, stmt: *c.sqlite3_stmt, allocator: std.mem.Allocator) !MemoryEntry {
        const id_ptr = c.sqlite3_column_text(stmt, 0);
        const type_ptr = c.sqlite3_column_text(stmt, 1);
        const content_ptr = c.sqlite3_column_text(stmt, 2);
        const created_ptr = c.sqlite3_column_text(stmt, 3);

        if (id_ptr == null or type_ptr == null or content_ptr == null or created_ptr == null) {
            return error.StepFailed;
        }

        const id = try allocator.dupe(u8, std.mem.span(id_ptr));
        errdefer allocator.free(id);

        const type_str = try allocator.dupe(u8, std.mem.span(type_ptr));
        errdefer allocator.free(type_str);

        const content = try allocator.dupe(u8, std.mem.span(content_ptr));
        errdefer allocator.free(content);

        const created_at = try allocator.dupe(u8, std.mem.span(created_ptr));
        errdefer allocator.free(created_at);

        const key = try allocator.dupe(u8, id);
        errdefer allocator.free(key);

        return MemoryEntry{
            .id = id,
            .key = key,
            .content = content,
            .category = .{ .custom = type_str },
            .timestamp = created_at,
        };
    }

    // ── VTable implementations ────────────────────────────────────────

    fn implName(_: *anyopaque) []const u8 {
        return "kg";
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: MemoryCategory, _: ?[]const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const cat_str = category.toString();

        if (std.mem.startsWith(u8, key, "__kg:entity:")) {
            const entity_id = key[12..];
            try self_.storeEntity(entity_id, cat_str, content);
        } else if (std.mem.startsWith(u8, key, "__kg:rel:")) {
            // Format: __kg:rel:{subject_id}:{predicate}:{object_id}
            const rel_part = key[9..];
            var it = std.mem.splitScalar(u8, rel_part, ':');
            const subject_id = it.next() orelse return error.StepFailed;
            const predicate = it.next() orelse return error.StepFailed;
            const object_id = it.rest();

            const rel_id = try generateId(self_.allocator);
            defer self_.allocator.free(rel_id);

            try self_.storeRelation(rel_id, subject_id, predicate, object_id);
        } else {
            // Generic key — treat as entity
            try self_.storeEntity(key, cat_str, content);
        }
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, _: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const trimmed = std.mem.trim(u8, query, " \t\n\r");
        if (trimmed.len == 0) return allocator.alloc(MemoryEntry, 0);

        if (std.mem.startsWith(u8, trimmed, "kg:traverse:")) {
            const args = trimmed[12..];
            var it = std.mem.splitScalar(u8, args, ':');
            const entity_id = it.next() orelse return allocator.alloc(MemoryEntry, 0);
            const depth_str = it.next() orelse "3";
            const max_depth = std.fmt.parseInt(usize, depth_str, 10) catch 3;
            return self_.traverse(allocator, entity_id, max_depth, limit);
        }

        if (std.mem.startsWith(u8, trimmed, "kg:path:")) {
            const args = trimmed[8..];
            var it = std.mem.splitScalar(u8, args, ':');
            const from_id = it.next() orelse return allocator.alloc(MemoryEntry, 0);
            const to_id = it.next() orelse return allocator.alloc(MemoryEntry, 0);
            const depth_str = it.next() orelse "5";
            const max_depth = std.fmt.parseInt(usize, depth_str, 10) catch 5;
            return self_.findPath(allocator, from_id, to_id, max_depth, limit);
        }

        if (std.mem.startsWith(u8, trimmed, "kg:relations:")) {
            const entity_id = trimmed[14..];
            if (entity_id.len == 0) return allocator.alloc(MemoryEntry, 0);
            return self_.getRelations(allocator, entity_id);
        }

        // Fall back to FTS5 content search
        return self_.ftsSearch(allocator, trimmed, limit);
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const sql = "SELECT id, type, content, created_at FROM kg_entities WHERE id = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            return try self_.readEntityFromRow(stmt.?, allocator);
        }
        return null;
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?MemoryCategory, _: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        var entries: std.ArrayListUnmanaged(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        const sql = if (category) |_|
            "SELECT id, type, content, created_at FROM kg_entities WHERE type = ?1 ORDER BY created_at DESC"
        else
            "SELECT id, type, content, created_at FROM kg_entities ORDER BY created_at DESC";

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (category) |cat| {
            const cat_str = cat.toString();
            _ = c.sqlite3_bind_text(stmt, 1, cat_str.ptr, @intCast(cat_str.len), SQLITE_STATIC);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const entry = try self_.readEntityFromRow(stmt.?, allocator);
            try entries.append(allocator, entry);
        }

        return entries.toOwnedSlice(allocator);
    }

    fn implForget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        // Try to delete as entity first
        {
            const sql = "DELETE FROM kg_entities WHERE id = ?1";
            var stmt: ?*c.sqlite3_stmt = null;
            var rc = c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null);
            if (rc != c.SQLITE_OK) return error.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), SQLITE_STATIC);
            rc = c.sqlite3_step(stmt);
            if (rc != c.SQLITE_DONE) return error.StepFailed;
            if (c.sqlite3_changes(self_.db) > 0) {
                // Also delete from FTS
                var fts_stmt: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self_.db, "DELETE FROM kg_entities_fts WHERE id = ?1", -1, &fts_stmt, null) == c.SQLITE_OK) {
                    defer _ = c.sqlite3_finalize(fts_stmt);
                    _ = c.sqlite3_bind_text(fts_stmt, 1, key.ptr, @intCast(key.len), SQLITE_STATIC);
                    _ = c.sqlite3_step(fts_stmt);
                }
                return true;
            }
        }

        // Try as relation id
        {
            const sql = "DELETE FROM kg_relations WHERE id = ?1";
            var stmt: ?*c.sqlite3_stmt = null;
            var rc = c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null);
            if (rc != c.SQLITE_OK) return error.PrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), SQLITE_STATIC);
            rc = c.sqlite3_step(stmt);
            if (rc != c.SQLITE_DONE) return error.StepFailed;
            return c.sqlite3_changes(self_.db) > 0;
        }
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const sql = "SELECT COUNT(*) FROM kg_entities";
        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(self_.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            return @intCast(c.sqlite3_column_int64(stmt, 0));
        }
        return 0;
    }

    fn implHealthCheck(ptr: *anyopaque) bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self_.db, "SELECT 1", null, null, &err_msg);
        if (err_msg) |msg| c.sqlite3_free(msg);
        return rc == c.SQLITE_OK;
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        self_.deinit();
        if (self_.owns_self) {
            self_.allocator.destroy(self_);
        }
    }

    pub const vtable = Memory.VTable{
        .name = &implName,
        .store = &implStore,
        .recall = &implRecall,
        .get = &implGet,
        .getScoped = null,
        .list = &implList,
        .forget = &implForget,
        .forgetScoped = null,
        .count = &implCount,
        .healthCheck = &implHealthCheck,
        .deinit = &implDeinit,
    };

    pub fn memory(self: *Self) Memory {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "kg memory init with in-memory db" {
    var kg = try KgMemory.init(std.testing.allocator, ":memory:");
    defer kg.deinit();
    const m = kg.memory();
    try std.testing.expect(m.healthCheck());
}

test "kg name" {
    var kg = try KgMemory.init(std.testing.allocator, ":memory:");
    defer kg.deinit();
    const m = kg.memory();
    try std.testing.expectEqualStrings("kg", m.name());
}

test "kg health check" {
    var kg = try KgMemory.init(std.testing.allocator, ":memory:");
    defer kg.deinit();
    const m = kg.memory();
    try std.testing.expect(m.healthCheck());
}

test "kg store and count" {
    var kg = try KgMemory.init(std.testing.allocator, ":memory:");
    defer kg.deinit();
    const m = kg.memory();

    try m.store("__kg:entity:test1", "Alice knows Bob", .core, null);
    try m.store("__kg:entity:test2", "Bob lives in NYC", .core, null);
    try m.store("__kg:rel:test1:knows:test2", "", .core, null);

    const count = try m.count();
    try std.testing.expect(count >= 2);
}

test "kg get entity" {
    var kg = try KgMemory.init(std.testing.allocator, ":memory:");
    defer kg.deinit();
    const m = kg.memory();

    try m.store("__kg:entity:e1", "Test entity content", .core, null);

    const entry = try m.get(std.testing.allocator, "e1");
    try std.testing.expect(entry != null);
    defer entry.?.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("e1", entry.?.key);
    try std.testing.expectEqualStrings("Test entity content", entry.?.content);
}
