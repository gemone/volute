const std = @import("std");
const treesitter = @import("treesitter.zig");
const grammar_mod = @import("grammar.zig");
const buffer_mod = @import("buffer.zig");
const syntax = @import("syntax.zig");
const ts = @import("tree-sitter");

pub const HighlightWorker = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,

    /// Worker-owned grammar handle. Accessed ONLY from worker thread.
    grammar: grammar_mod.GrammarHandle,

    // --- Request side (main → worker) ---
    req_mutex: std.Io.Mutex,
    req_cond: std.Io.Condition,
    pending_req: ?Request,
    shutdown: bool,

    // --- Result side (worker → main) ---
    res_mutex: std.Io.Mutex,
    pending_res: ?Result,

    thread: std.Thread,

    pub const Request = struct {
        /// Source snapshot — heap copy owned by Request, freed by worker after use.
        source: []u8,
        version: u64,
        scroll: usize,
        q_start: u32,
        q_end: u32,
        tree_edit: ?buffer_mod.TreeEditHint,
    };

    pub const Result = struct {
        /// Highlight styles (owned by caller after tryTakeResult()).
        styles: []syntax.TokenStyle,
        version: u64,
        scroll: usize,
        /// Changed parse-tree ranges for targeted dirty-line marking.
        /// Null when this is the first parse (no old tree to diff against).
        changed_ranges: ?[]ts.Range,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, grammar: grammar_mod.GrammarHandle) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .grammar = grammar,
            .req_mutex = .init,
            .req_cond = .init,
            .pending_req = null,
            .shutdown = false,
            .res_mutex = .init,
            .pending_res = null,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Signal shutdown and wake worker.
        self.req_mutex.lockUncancelable(self.io);
        self.shutdown = true;
        if (self.pending_req) |r| self.allocator.free(r.source);
        self.pending_req = null;
        self.req_mutex.unlock(self.io);
        self.req_cond.signal(self.io);

        self.thread.join();

        // Free leftover result.
        self.res_mutex.lockUncancelable(self.io);
        if (self.pending_res) |r| {
            self.allocator.free(r.styles);
            if (r.changed_ranges) |cr| self.allocator.free(cr);
        }
        self.pending_res = null;
        self.res_mutex.unlock(self.io);

        self.grammar.deinit();
        self.allocator.destroy(self);
    }

    /// Submit a highlight request. Non-blocking; latest request wins (older dropped).
    pub fn submit(self: *Self, req: Request) void {
        self.req_mutex.lockUncancelable(self.io);
        defer self.req_mutex.unlock(self.io);
        if (self.pending_req) |old| self.allocator.free(old.source);
        self.pending_req = req;
        self.req_cond.signal(self.io);
    }

    /// Try to take a completed result. Returns null if no result is ready.
    /// Caller owns Result.styles and Result.changed_ranges.
    pub fn tryTakeResult(self: *Self) ?Result {
        self.res_mutex.lockUncancelable(self.io);
        defer self.res_mutex.unlock(self.io);
        const r = self.pending_res orelse return null;
        self.pending_res = null;
        return r;
    }

    /// Returns true if a new result is waiting (without consuming it).
    pub fn hasResult(self: *Self) bool {
        self.res_mutex.lockUncancelable(self.io);
        defer self.res_mutex.unlock(self.io);
        return self.pending_res != null;
    }

    fn workerLoop(self: *Self) void {
        while (true) {
            self.req_mutex.lockUncancelable(self.io);
            while (self.pending_req == null and !self.shutdown) {
                self.req_cond.waitUncancelable(self.io, &self.req_mutex);
            }
            if (self.shutdown) {
                self.req_mutex.unlock(self.io);
                return;
            }
            const req = self.pending_req.?;
            self.pending_req = null;
            self.req_mutex.unlock(self.io);

            // Process request — no locks held (GrammarHandle is worker-exclusive).
            const hl_result = treesitter.highlightVersioned(
                self.allocator,
                &self.grammar,
                req.source,
                req.version,
                req.tree_edit,
                req.q_start,
                req.q_end,
            ) catch {
                self.allocator.free(req.source);
                continue;
            };
            self.allocator.free(req.source);

            // Publish result — free old unread result if present.
            self.res_mutex.lockUncancelable(self.io);
            if (self.pending_res) |old| {
                self.allocator.free(old.styles);
                if (old.changed_ranges) |cr| self.allocator.free(cr);
            }
            self.pending_res = .{
                .styles = hl_result.styles,
                .version = req.version,
                .scroll = req.scroll,
                .changed_ranges = hl_result.changed_ranges,
            };
            self.res_mutex.unlock(self.io);
        }
    }
};

