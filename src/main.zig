const std = @import("std");
const Allocator = std.mem.Allocator;
const allocator = std.heap.wasm_allocator;

const PX_FREQ_N: usize = 257;
const PX_FREQ_END: usize = 256;
const PX_FREQ_MAX: u32 = 128;
const PX_CODE_BITS: u5 = 24;
const PX_CODE_BITS_INV: u5 = 8;
const PX_FREQ_MAX_BITS: u5 = 14;
const PX_PROB_MAX_VALUE: u32 = @as(u32, 1) << PX_FREQ_MAX_BITS;
const PX_CODE_MAX_VALUE: u32 = (@as(u32, 1) << PX_CODE_BITS) - 1;

const HASH_MULT_N: u32 = 1540483477;
const HASH_MULT_W: u32 = 3332679571;
const HASH_MULT_NW: u32 = 3432918353;
const HASH_MULT_NE: u32 = 2246822507;
const HASH_MULT_NN: u32 = 2146121005;
const HASH_MULT_WW: u32 = 2890668881;
const HASH_MULT_NNW: u32 = 830770091;
const HASH_MULT_NNE: u32 = 1935289751;
const HASH_MULT_NWW: u32 = 2943497623;
const HASH_CTX_BITS: u5 = 16;
const HASH_CTX_SIZE: usize = @as(usize, 1) << HASH_CTX_BITS;

const ModelKind = enum(u8) {
    hash = 0,
    nw = 1,
    w = 2,
};
const ALL_MODELS = [_]ModelKind{ .hash, .nw, .w };
const NUM_MODELS: usize = ALL_MODELS.len;

const PPR_W0: u32 = 4;
const PPR_W1: u32 = 2;
const PPR_W2: u32 = 1;
const PPR_W3: u32 = 2;
const PPR_W4: u32 = 1;

var last_encoded: ?[]u8 = null;
var last_decoded: ?DecodedSprites = null;

const Prob = struct {
    low: u32,
    high: u32,
    scale: u32,
};

const Context = struct {
    freq: []u16,
    sum: u32,
};

const Model = struct {
    kind: ModelKind,
    index_escape: usize,
    index_end: usize,
    contexts: []Context,
    backing: []u16,

    fn init(alloc: Allocator, kind: ModelKind, palette_size: usize) !Model {
        const index_escape = palette_size;
        const index_end = palette_size + 1;
        var num_ctx: usize = 1;
        switch (kind) {
            .hash => num_ctx += HASH_CTX_SIZE,
            .nw => num_ctx += index_end * index_end,
            .w => num_ctx += index_end,
        }
        const backing = try alloc.alloc(u16, num_ctx * PX_FREQ_N);
        @memset(backing, 0);
        const contexts = try alloc.alloc(Context, num_ctx);
        for (0..num_ctx) |i| {
            contexts[i] = .{
                .freq = backing[i * PX_FREQ_N .. i * PX_FREQ_N + PX_FREQ_N],
                .sum = 0,
            };
        }
        for (0..palette_size) |i| contexts[0].freq[i] = 1;
        contexts[0].sum = @intCast(palette_size);
        return .{
            .kind = kind,
            .index_escape = index_escape,
            .index_end = index_end,
            .contexts = contexts,
            .backing = backing,
        };
    }

    fn deinit(self: *Model, alloc: Allocator) void {
        alloc.free(self.contexts);
        alloc.free(self.backing);
    }

    fn buildContext(self: *Model, idx: []const u8, pos: usize, x: usize, y: usize, w: usize) *Context {
        const sent: i32 = @intCast(self.index_escape);
        const end: i32 = @intCast(self.index_end);
        const wv: i32 = if (x > 0) @intCast(idx[pos - 1]) else sent;
        const nv: i32 = if (y > 0) @intCast(idx[pos - w]) else sent;
        switch (self.kind) {
            .hash => {
                const nwv: i32 = if (x > 0 and y > 0) @intCast(idx[pos - w - 1]) else sent;
                const nnv: i32 = if (y > 1) @intCast(idx[pos - 2 * w]) else sent;
                const wwv: i32 = if (x > 1) @intCast(idx[pos - 2]) else sent;
                const nev: i32 = if (x + 1 < w and y > 0) @intCast(idx[pos - w + 1]) else sent;
                const nnwv: i32 = if (y > 1 and x > 0) @intCast(idx[pos - 2 * w - 1]) else sent;
                const nnev: i32 = if (y > 1 and x + 1 < w) @intCast(idx[pos - 2 * w + 1]) else sent;
                const nwwv: i32 = if (x > 1 and y > 0) @intCast(idx[pos - w - 2]) else sent;
                var h: u32 = @as(u32, @bitCast(nv)) *% HASH_MULT_N;
                h = h +% (@as(u32, @bitCast(wv)) *% HASH_MULT_W);
                h = h +% (@as(u32, @bitCast(nwv)) *% HASH_MULT_NW);
                h = h +% (@as(u32, @bitCast(nev)) *% HASH_MULT_NE);
                h = h +% (@as(u32, @bitCast(nnv)) *% HASH_MULT_NN);
                h = h +% (@as(u32, @bitCast(wwv)) *% HASH_MULT_WW);
                h = h +% (@as(u32, @bitCast(nnwv)) *% HASH_MULT_NNW);
                h = h +% (@as(u32, @bitCast(nnev)) *% HASH_MULT_NNE);
                h = h +% (@as(u32, @bitCast(nwwv)) *% HASH_MULT_NWW);
                h ^= h >> 15;
                return &self.contexts[1 + (h & (HASH_CTX_SIZE - 1))];
            },
            .nw => {
                const i: usize = @intCast(nv * end + wv);
                return &self.contexts[1 + i];
            },
            .w => {
                const i: usize = @intCast(wv);
                return &self.contexts[1 + i];
            },
        }
    }
};

const Encoder = struct {
    data: []u8,
    offset: usize,
    low: u32,
    range: u32,

    fn init(data: []u8) Encoder {
        return .{ .data = data, .offset = 0, .low = 0, .range = 0xffffffff };
    }

    fn encode(self: *Encoder, prob: Prob) void {
        self.range /= prob.scale;
        self.low = self.low +% (prob.low *% self.range);
        self.range = self.range *% (prob.high - prob.low);
    }

    fn normalize(self: *Encoder) void {
        while (true) {
            const sum = self.low +% self.range;
            if ((self.low ^ sum) >= PX_CODE_MAX_VALUE) {
                if (self.range >= PX_PROB_MAX_VALUE) break;
                self.range = PX_PROB_MAX_VALUE -% (self.low & (PX_PROB_MAX_VALUE - 1));
            }
            const byte: u8 = @truncate(self.low >> PX_CODE_BITS);
            self.low = self.low << PX_CODE_BITS_INV;
            self.range = self.range << PX_CODE_BITS_INV;
            self.data[self.offset] = byte;
            self.offset += 1;
        }
    }

    fn flush(self: *Encoder) void {
        for (0..4) |_| {
            const byte: u8 = @truncate(self.low >> PX_CODE_BITS);
            self.low = self.low << PX_CODE_BITS_INV;
            self.data[self.offset] = byte;
            self.offset += 1;
        }
    }
};

const Decoder = struct {
    data: []const u8,
    offset: usize,
    end: usize,
    low: u32,
    range: u32,
    code: u32,

    fn init(data: []const u8, size: usize) Decoder {
        var self = Decoder{ .data = data, .offset = 0, .end = size, .low = 0, .range = 0xffffffff, .code = 0 };
        for (0..4) |_| {
            const b: u32 = if (self.offset < self.end) blk: {
                const v = self.data[self.offset];
                self.offset += 1;
                break :blk v;
            } else 0;
            self.code = (self.code << 8) | b;
        }
        return self;
    }

    fn currFreq(self: *Decoder, scale: u32) u32 {
        self.range /= scale;
        return (self.code -% self.low) / self.range;
    }

    fn update(self: *Decoder, prob: Prob) void {
        self.low = self.low +% (self.range *% prob.low);
        self.range = self.range *% (prob.high - prob.low);
        while (true) {
            const sum = self.low +% self.range;
            if ((self.low ^ sum) >= PX_CODE_MAX_VALUE) {
                if (self.range < PX_PROB_MAX_VALUE) {
                    self.range = PX_PROB_MAX_VALUE -% (self.low & (PX_PROB_MAX_VALUE - 1));
                } else break;
            } else break;
            const in_byte: u32 = if (self.offset < self.end) blk: {
                const v = self.data[self.offset];
                self.offset += 1;
                break :blk v;
            } else 0;
            self.code = (self.code << 8) | in_byte;
            self.range = self.range << 8;
            self.low = self.low << 8;
        }
    }
};

fn arithGetProb(ctx: *const Context, symbol: usize) Prob {
    var low: u32 = 0;
    for (0..symbol) |i| low += ctx.freq[i];
    return .{ .low = low, .high = low + ctx.freq[symbol], .scale = ctx.sum };
}

fn getSymFromFreq(ctx: *const Context, target_freq: u32) struct { prob: Prob, symbol: usize } {
    var s: usize = 0;
    var cum: u32 = 0;
    while (s <= PX_FREQ_END) : (s += 1) {
        cum += ctx.freq[s];
        if (cum > target_freq) break;
    }
    if (s > PX_FREQ_END) s = PX_FREQ_END;
    const low = cum - ctx.freq[s];
    return .{ .prob = .{ .low = low, .high = cum, .scale = ctx.sum }, .symbol = s };
}

fn contextUpdate(ctx: *Context, symbol: usize, freq_max: *u32, palette_size: usize) void {
    ctx.freq[symbol] += 2;
    ctx.sum += 2;
    if (ctx.freq[symbol] >= freq_max.* or ctx.sum >= PX_PROB_MAX_VALUE) {
        freq_max.* += @intCast((PX_FREQ_END - palette_size) >> 1);
        ctx.sum = 0;
        for (0..PX_FREQ_N) |i| {
            const val = ctx.freq[i];
            if (val == 0) continue;
            const scaled: u16 = (val + 1) >> 1;
            ctx.freq[i] = scaled;
            ctx.sum += scaled;
        }
    }
}

fn encodeModel(alloc: Allocator, idx: []const u8, w: usize, h: usize, palette_size: usize, model_kind: ModelKind, out: []u8) !usize {
    var m = try Model.init(alloc, model_kind, palette_size);
    defer m.deinit(alloc);
    const escape = m.index_escape;
    var ac = Encoder.init(out);
    var freq_max: u32 = PX_FREQ_MAX;
    var pos: usize = 0;
    for (0..h) |y| {
        for (0..w) |x| {
            const sym = idx[pos];
            const ctx = m.buildContext(idx, pos, x, y, w);
            var encoded = false;
            if (ctx.sum != 0) {
                if (ctx.freq[sym] != 0) {
                    const prob = arithGetProb(ctx, sym);
                    ac.encode(prob);
                    ac.normalize();
                    contextUpdate(ctx, sym, &freq_max, palette_size);
                    encoded = true;
                } else {
                    const prob = arithGetProb(ctx, escape);
                    ac.encode(prob);
                    ac.normalize();
                    ctx.freq[escape] += 1;
                    ctx.sum += 1;
                }
            }
            if (!encoded) {
                const order0 = &m.contexts[0];
                const prob = arithGetProb(order0, sym);
                ac.encode(prob);
                ac.normalize();
                contextUpdate(order0, sym, &freq_max, palette_size);
                if (ctx.sum == 0) {
                    ctx.freq[escape] = 1;
                    ctx.sum = 1;
                }
                ctx.freq[sym] = 1;
                ctx.sum += 1;
            }
            pos += 1;
        }
    }
    ac.flush();
    return ac.offset;
}

fn decodeModel(alloc: Allocator, in_bytes: []const u8, in_size: usize, w: usize, h: usize, palette_size: usize, model_kind: ModelKind, idx: []u8) !void {
    var m = try Model.init(alloc, model_kind, palette_size);
    defer m.deinit(alloc);
    const escape = m.index_escape;
    var ac = Decoder.init(in_bytes, in_size);
    var freq_max: u32 = PX_FREQ_MAX;
    var pos: usize = 0;
    for (0..h) |y| {
        for (0..w) |x| {
            const ctx = m.buildContext(idx, pos, x, y, w);
            var sym: u8 = 0;
            var decoded = false;
            if (ctx.sum != 0) {
                const f = ac.currFreq(ctx.sum);
                const r = getSymFromFreq(ctx, f);
                ac.update(r.prob);
                if (r.symbol != escape) {
                    sym = @intCast(r.symbol);
                    contextUpdate(ctx, r.symbol, &freq_max, palette_size);
                    decoded = true;
                } else {
                    ctx.freq[escape] += 1;
                    ctx.sum += 1;
                }
            }
            if (!decoded) {
                const order0 = &m.contexts[0];
                const f = ac.currFreq(order0.sum);
                const r = getSymFromFreq(order0, f);
                ac.update(r.prob);
                sym = @intCast(r.symbol);
                contextUpdate(order0, r.symbol, &freq_max, palette_size);
                if (ctx.sum == 0) {
                    ctx.freq[escape] = 1;
                    ctx.sum = 1;
                }
                ctx.freq[sym] = 1;
                ctx.sum += 1;
            }
            idx[pos] = sym;
            pos += 1;
        }
    }
}

fn medPredict(left: u32, top: u32, top_left: u32) u32 {
    if (top_left >= @max(left, top)) return @min(left, top);
    if (top_left <= @min(left, top)) return @max(left, top);
    return left +% top -% top_left;
}

fn quantizeToPalette(rgb: u32, palette: []const u32) usize {
    var best_idx: usize = 0;
    var best_dist: i64 = std.math.maxInt(i64);
    for (palette, 0..) |c, i| {
        const dr: i64 = @as(i64, @intCast(c & 0xff)) - @as(i64, @intCast(rgb & 0xff));
        const dg: i64 = @as(i64, @intCast((c >> 8) & 0xff)) - @as(i64, @intCast((rgb >> 8) & 0xff));
        const db: i64 = @as(i64, @intCast((c >> 16) & 0xff)) - @as(i64, @intCast((rgb >> 16) & 0xff));
        const dist = dr * dr + dg * dg + db * db;
        if (dist < best_dist) {
            best_dist = dist;
            best_idx = i;
        }
    }
    return best_idx;
}

const PPRTables = struct {
    td: []u32,
    tw: []u32,
    tnw: []u32,
    tn: []u32,
    tne: []u32,

    fn init(alloc: Allocator, n: usize) !PPRTables {
        const size = n * n;
        const td = try alloc.alloc(u32, size);
        const tw = try alloc.alloc(u32, size);
        const tnw = try alloc.alloc(u32, size);
        const tn = try alloc.alloc(u32, size);
        const tne = try alloc.alloc(u32, size);
        @memset(td, 1);
        @memset(tw, 1);
        @memset(tnw, 1);
        @memset(tn, 1);
        @memset(tne, 1);
        return .{ .td = td, .tw = tw, .tnw = tnw, .tn = tn, .tne = tne };
    }

    fn deinit(self: *PPRTables, alloc: Allocator) void {
        alloc.free(self.td);
        alloc.free(self.tw);
        alloc.free(self.tnw);
        alloc.free(self.tn);
        alloc.free(self.tne);
    }
};

fn getColor(palette: []const u32, idx: i32) u32 {
    return if (idx >= 0) palette[@intCast(idx)] else 0;
}

fn ppRank(
    alloc: Allocator,
    tables: *PPRTables,
    palette: []const u32,
    n: usize,
    x: usize,
    y: usize,
    w: usize,
    r_w: i32,
    r_nw: i32,
    r_n: i32,
    r_ne: i32,
) !struct { sorted: []usize, pr: u32, pg: u32, pb: u32 } {
    _ = x;
    _ = y;
    _ = w;
    const a = getColor(palette, r_w);
    const b = getColor(palette, r_n);
    const c = getColor(palette, r_nw);
    const pr = medPredict(a & 0xff, b & 0xff, c & 0xff);
    const pg = medPredict((a >> 8) & 0xff, (b >> 8) & 0xff, (c >> 8) & 0xff);
    const pb = medPredict((a >> 16) & 0xff, (b >> 16) & 0xff, (c >> 16) & 0xff);
    const pred_rgb = (pb << 16) | (pg << 8) | pr;
    const p = quantizeToPalette(pred_rgb, palette);

    const l = try alloc.alloc(i64, n);
    defer alloc.free(l);
    for (0..n) |k| {
        var val: i64 = @as(i64, PPR_W0) * @as(i64, tables.td[p * n + k]);
        if (r_w >= 0) val += @as(i64, PPR_W1) * @as(i64, tables.tw[@as(usize, @intCast(r_w)) * n + k]);
        if (r_nw >= 0) val += @as(i64, PPR_W2) * @as(i64, tables.tnw[@as(usize, @intCast(r_nw)) * n + k]);
        if (r_n >= 0) val += @as(i64, PPR_W3) * @as(i64, tables.tn[@as(usize, @intCast(r_n)) * n + k]);
        if (r_ne >= 0) val += @as(i64, PPR_W4) * @as(i64, tables.tne[@as(usize, @intCast(r_ne)) * n + k]);
        l[k] = val;
    }

    const sorted = try alloc.alloc(usize, n);
    for (0..n) |i| sorted[i] = i;

    const Ctx = struct {
        l: []i64,
        palette: []const u32,
        pr: u32,
        pg: u32,
        pb: u32,

        fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
            if (ctx.l[rhs] != ctx.l[lhs]) return ctx.l[rhs] < ctx.l[lhs];
            const ci = ctx.palette[lhs];
            const cj = ctx.palette[rhs];
            const inv_r = 0xff -% ctx.pr;
            const inv_g = 0xff -% ctx.pg;
            const inv_b = 0xff -% ctx.pb;
            const di = std.math.pow(i64, @intCast(ci & inv_r), 2) + std.math.pow(i64, @intCast((ci >> 8) & inv_g), 2) + std.math.pow(i64, @intCast((ci >> 16) & inv_b), 2);
            const dj = std.math.pow(i64, @intCast(cj & inv_r), 2) + std.math.pow(i64, @intCast((cj >> 8) & inv_g), 2) + std.math.pow(i64, @intCast((cj >> 16) & inv_b), 2);
            if (di != dj) return di < dj;
            return lhs < rhs;
        }
    };

    std.sort.pdq(usize, sorted, Ctx{ .l = l, .palette = palette, .pr = pr, .pg = pg, .pb = pb }, Ctx.lessThan);

    return .{ .sorted = sorted, .pr = pr, .pg = pg, .pb = pb };
}

fn applyPPR(alloc: Allocator, palette: []const u32, orig_idx: []const u8, width: usize, height: usize) ![]u8 {
    const n = palette.len;
    var tables = try PPRTables.init(alloc, n);
    defer tables.deinit(alloc);
    const new_idx = try alloc.alloc(u8, orig_idx.len);
    var pos: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const r: usize = orig_idx[pos];
            const r_w: i32 = if (x > 0) @intCast(orig_idx[pos - 1]) else -1;
            const r_nw: i32 = if (x > 0 and y > 0) @intCast(orig_idx[pos - width - 1]) else -1;
            const r_n: i32 = if (y > 0) @intCast(orig_idx[pos - width]) else -1;
            const r_ne: i32 = if (x + 1 < width and y > 0) @intCast(orig_idx[pos - width + 1]) else -1;

            const result = try ppRank(alloc, &tables, palette, n, x, y, width, r_w, r_nw, r_n, r_ne);
            defer alloc.free(result.sorted);

            var new_sym: usize = 0;
            for (result.sorted, 0..) |v, i| {
                if (v == r) {
                    new_sym = i;
                    break;
                }
            }
            new_idx[pos] = @intCast(new_sym);

            const p = blk: {
                const a = getColor(palette, r_w);
                const b = getColor(palette, r_n);
                const c = getColor(palette, r_nw);
                const pr = medPredict(a & 0xff, b & 0xff, c & 0xff);
                const pg = medPredict((a >> 8) & 0xff, (b >> 8) & 0xff, (c >> 8) & 0xff);
                const pb = medPredict((a >> 16) & 0xff, (b >> 16) & 0xff, (c >> 16) & 0xff);
                const pred_rgb = (pb << 16) | (pg << 8) | pr;
                break :blk quantizeToPalette(pred_rgb, palette);
            };
            tables.td[p * n + r] += 1;
            if (r_w >= 0) tables.tw[@as(usize, @intCast(r_w)) * n + r] += 1;
            if (r_nw >= 0) tables.tnw[@as(usize, @intCast(r_nw)) * n + r] += 1;
            if (r_n >= 0) tables.tn[@as(usize, @intCast(r_n)) * n + r] += 1;
            if (r_ne >= 0) tables.tne[@as(usize, @intCast(r_ne)) * n + r] += 1;

            pos += 1;
        }
    }
    return new_idx;
}

fn reversePPR(alloc: Allocator, palette: []const u32, new_idx: []const u8, width: usize, height: usize) ![]u8 {
    const n = palette.len;
    var tables = try PPRTables.init(alloc, n);
    defer tables.deinit(alloc);
    const orig_idx = try alloc.alloc(u8, new_idx.len);
    @memset(orig_idx, 0);
    var pos: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const r_w: i32 = if (x > 0) @intCast(orig_idx[pos - 1]) else -1;
            const r_nw: i32 = if (x > 0 and y > 0) @intCast(orig_idx[pos - width - 1]) else -1;
            const r_n: i32 = if (y > 0) @intCast(orig_idx[pos - width]) else -1;
            const r_ne: i32 = if (x + 1 < width and y > 0) @intCast(orig_idx[pos - width + 1]) else -1;

            const result = try ppRank(alloc, &tables, palette, n, x, y, width, r_w, r_nw, r_n, r_ne);
            defer alloc.free(result.sorted);

            const r = result.sorted[new_idx[pos]];
            orig_idx[pos] = @intCast(r);

            const p = blk: {
                const a = getColor(palette, r_w);
                const b = getColor(palette, r_n);
                const c = getColor(palette, r_nw);
                const pr = medPredict(a & 0xff, b & 0xff, c & 0xff);
                const pg = medPredict((a >> 8) & 0xff, (b >> 8) & 0xff, (c >> 8) & 0xff);
                const pb = medPredict((a >> 16) & 0xff, (b >> 16) & 0xff, (c >> 16) & 0xff);
                const pred_rgb = (pb << 16) | (pg << 8) | pr;
                break :blk quantizeToPalette(pred_rgb, palette);
            };
            tables.td[p * n + r] += 1;
            if (r_w >= 0) tables.tw[@as(usize, @intCast(r_w)) * n + r] += 1;
            if (r_nw >= 0) tables.tnw[@as(usize, @intCast(r_nw)) * n + r] += 1;
            if (r_n >= 0) tables.tn[@as(usize, @intCast(r_n)) * n + r] += 1;
            if (r_ne >= 0) tables.tne[@as(usize, @intCast(r_ne)) * n + r] += 1;

            pos += 1;
        }
    }
    return orig_idx;
}

const CompressedIndexMap = struct {
    bytes: []u8,
    bytes_size: usize,
    model: ModelKind,
};

fn compressIndexMap(alloc: Allocator, idx: []const u8, w: usize, h: usize, palette_size: usize, tmp: []u8) !CompressedIndexMap {
    var best_size: usize = 0;
    var best_model: ModelKind = .hash;
    var best = try alloc.alloc(u8, tmp.len);
    for (ALL_MODELS) |model| {
        const size = try encodeModel(alloc, idx, w, h, palette_size, model, tmp);
        if (size == 0) continue;
        if (best_size == 0 or size < best_size) {
            best_size = size;
            best_model = model;
            @memcpy(best[0..size], tmp[0..size]);
        }
    }
    const result = try alloc.alloc(u8, best_size);
    @memcpy(result, best[0..best_size]);
    alloc.free(best);
    return .{ .bytes = result, .bytes_size = best_size, .model = best_model };
}

fn varintSize(v_in: usize) usize {
    var v = v_in;
    var n: usize = 1;
    while (v >= 0x80) {
        n += 1;
        v >>= 7;
    }
    return n;
}

pub const Sprite = struct {
    data: []const u8,
    width: usize,
    height: usize,
};

pub const OwnedSprite = struct {
    data: []u8,
    width: usize,
    height: usize,
};

pub const SharedPalette = struct {
    palette: []u32,
    idx_arrays: [][]u8,

    pub fn deinit(self: *SharedPalette, alloc: Allocator) void {
        alloc.free(self.palette);
        for (self.idx_arrays) |arr| alloc.free(arr);
        alloc.free(self.idx_arrays);
    }
};

pub fn buildSharedPalette(alloc: Allocator, sprites: []const []const u32) !SharedPalette {
    var map = std.AutoHashMap(u32, usize).init(alloc);
    defer map.deinit();
    var palette = std.ArrayList(u32){};
    defer palette.deinit(alloc);
    try palette.append(alloc, 0x00000000);

    var idx_arrays = try alloc.alloc([]u8, sprites.len);
    for (sprites, 0..) |pixels, si| {
        const idx = try alloc.alloc(u8, pixels.len);
        for (pixels, 0..) |c, i| {
            if ((c >> 24) == 0) {
                idx[i] = 0;
                continue;
            }
            const rgb = c & 0xffffff;
            const entry = try map.getOrPut(rgb);
            if (!entry.found_existing) {
                entry.value_ptr.* = palette.items.len;
                try palette.append(alloc, 0xff000000 | rgb);
            }
            idx[i] = @intCast(entry.value_ptr.*);
        }
        idx_arrays[si] = idx;
    }

    return .{
        .palette = try palette.toOwnedSlice(alloc),
        .idx_arrays = idx_arrays,
    };
}

pub fn encode(alloc: Allocator, sprites: []const Sprite, palette: []const u32) ![]u8 {
    const n = palette.len;
    var max_area: usize = 0;
    for (sprites) |s| max_area = @max(max_area, s.width * s.height);
    const tmp = try alloc.alloc(u8, max_area * 4 + 64);
    defer alloc.free(tmp);

    const Compressed = struct {
        bytes: []u8,
        bytes_size: usize,
        model: ModelKind,
        width: usize,
        height: usize,
        use_ppr: bool,
    };

    var compressed = try alloc.alloc(Compressed, sprites.len);
    defer {
        for (compressed) |c| alloc.free(c.bytes);
        alloc.free(compressed);
    }

    for (sprites, 0..) |sprite, i| {
        const no_ppr = try compressIndexMap(alloc, sprite.data, sprite.width, sprite.height, n, tmp);
        const ppr_idx = try applyPPR(alloc, palette, sprite.data, sprite.width, sprite.height);
        defer alloc.free(ppr_idx);
        const with_ppr = try compressIndexMap(alloc, ppr_idx, sprite.width, sprite.height, n, tmp);

        const use_ppr = with_ppr.bytes_size != 0 and with_ppr.bytes_size < no_ppr.bytes_size;
        if (use_ppr) {
            alloc.free(no_ppr.bytes);
            compressed[i] = .{
                .bytes = with_ppr.bytes,
                .bytes_size = with_ppr.bytes_size,
                .model = with_ppr.model,
                .width = sprite.width,
                .height = sprite.height,
                .use_ppr = true,
            };
        } else {
            alloc.free(with_ppr.bytes);
            compressed[i] = .{
                .bytes = no_ppr.bytes,
                .bytes_size = no_ppr.bytes_size,
                .model = no_ppr.model,
                .width = sprite.width,
                .height = sprite.height,
                .use_ppr = false,
            };
        }
    }

    const palette_count = n - 1;
    var total_size: usize = 1 + 1 + palette_count * 3;
    for (compressed) |c| {
        const is_small = (c.width - 1) <= 255 and (c.height - 1) <= 255;
        total_size += 2 + (if (is_small) @as(usize, 2) else @as(usize, 3)) + varintSize(c.bytes_size) + c.bytes_size;
    }

    var out = try alloc.alloc(u8, total_size);
    var off: usize = 0;
    out[off] = @intCast(sprites.len);
    off += 1;
    out[off] = @intCast(palette_count & 0xff);
    off += 1;
    for (1..n) |i| {
        const c = palette[i];
        out[off] = @truncate(c & 0xff);
        off += 1;
        out[off] = @truncate((c >> 8) & 0xff);
        off += 1;
        out[off] = @truncate((c >> 16) & 0xff);
        off += 1;
    }

    for (compressed) |c| {
        const w = c.width - 1;
        const h = c.height - 1;
        const is_small = w <= 255 and h <= 255;
        out[off] = (if (is_small) @as(u8, 1) else @as(u8, 0)) | (if (c.use_ppr) @as(u8, 2) else @as(u8, 0));
        off += 1;
        out[off] = @intFromEnum(c.model);
        off += 1;
        if (is_small) {
            out[off] = @intCast(w & 0xff);
            off += 1;
            out[off] = @intCast(h & 0xff);
            off += 1;
        } else {
            const packed_val: u32 = (@as(u32, @intCast(w & 0xfff)) << 12) | @as(u32, @intCast(h & 0xfff));
            out[off] = @truncate((packed_val >> 16) & 0xff);
            off += 1;
            out[off] = @truncate((packed_val >> 8) & 0xff);
            off += 1;
            out[off] = @truncate(packed_val & 0xff);
            off += 1;
        }
        var size = c.bytes_size;
        while (size >= 0x80) {
            out[off] = @intCast((size | 0x80) & 0xff);
            off += 1;
            size >>= 7;
        }
        out[off] = @intCast(size);
        off += 1;
        @memcpy(out[off .. off + c.bytes_size], c.bytes[0..c.bytes_size]);
        off += c.bytes_size;
    }

    return out;
}

pub const DecodedSprites = struct {
    palette: []u32,
    sprites: []OwnedSprite,

    pub fn deinit(self: *DecodedSprites, alloc: Allocator) void {
        alloc.free(self.palette);
        for (self.sprites) |s| alloc.free(s.data);
        alloc.free(self.sprites);
    }
};

pub fn decode(alloc: Allocator, bytes: []const u8) !DecodedSprites {
    var off: usize = 0;
    const sprite_count = bytes[off];
    off += 1;
    var palette_count: usize = bytes[off];
    off += 1;
    if (palette_count == 0) palette_count = 256;

    var palette = try alloc.alloc(u32, palette_count + 1);
    palette[0] = 0x00000000;
    for (1..palette_count + 1) |i| {
        const r = bytes[off];
        off += 1;
        const g = bytes[off];
        off += 1;
        const b = bytes[off];
        off += 1;
        palette[i] = 0xff000000 | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
    }

    var sprites = try alloc.alloc(OwnedSprite, sprite_count);
    for (0..sprite_count) |s| {
        const flags = bytes[off];
        off += 1;
        const model_byte = bytes[off];
        off += 1;
        const model: ModelKind = @enumFromInt(model_byte);
        const is_small = (flags & 1) != 0;
        const use_ppr = (flags & 2) != 0;

        var w: usize = undefined;
        var h: usize = undefined;
        if (is_small) {
            w = @as(usize, bytes[off]) + 1;
            off += 1;
            h = @as(usize, bytes[off]) + 1;
            off += 1;
        } else {
            const packed_val: u32 = (@as(u32, bytes[off]) << 16) | (@as(u32, bytes[off + 1]) << 8) | bytes[off + 2];
            off += 3;
            w = @as(usize, (packed_val >> 12) & 0xfff) + 1;
            h = @as(usize, packed_val & 0xfff) + 1;
        }

        var bytes_size: usize = 0;
        var shift: u6 = 0;
        var bv: u8 = undefined;
        while (true) {
            bv = bytes[off];
            off += 1;
            if (shift < 32) bytes_size |= @as(usize, bv & 0x7f) << @intCast(shift);
            shift += 7;
            if ((bv & 0x80) == 0 or shift >= 35) break;
        }

        const img_bytes = bytes[off .. off + bytes_size];
        off += bytes_size;

        const decoded_idx = try alloc.alloc(u8, w * h);
        defer alloc.free(decoded_idx);
        @memset(decoded_idx, 0);
        try decodeModel(alloc, img_bytes, bytes_size, w, h, palette.len, model, decoded_idx);

        const data = if (use_ppr)
            try reversePPR(alloc, palette, decoded_idx, w, h)
        else
            try alloc.dupe(u8, decoded_idx);

        sprites[s] = .{ .data = data, .width = w, .height = h };
    }

    return .{ .palette = palette, .sprites = sprites };
}

export fn wasmAlloc(size: usize) [*]allowzero u8 {
    const buf = allocator.alloc(u8, size) catch return @ptrFromInt(0);
    return buf.ptr;
}

export fn wasmFree(ptr: [*]u8, size: usize) void {
    allocator.free(ptr[0..size]);
}

export fn encodeSprites(
    sprite_data_ptrs: [*]const [*]const u8,
    sprite_widths: [*]const u32,
    sprite_heights: [*]const u32,
    sprite_count: u32,
    palette_ptr: [*]const u32,
    palette_count: u32,
) [*]allowzero const u8 {
    if (last_encoded) |buf| {
        allocator.free(buf);
        last_encoded = null;
    }

    const palette = palette_ptr[0..palette_count];

    var sprites = allocator.alloc(Sprite, sprite_count) catch return @ptrFromInt(0);
    defer allocator.free(sprites);

    for (0..sprite_count) |i| {
        const w: usize = sprite_widths[i];
        const h: usize = sprite_heights[i];
        sprites[i] = .{
            .data = sprite_data_ptrs[i][0 .. w * h],
            .width = w,
            .height = h,
        };
    }

    const result = encode(allocator, sprites, palette) catch return @ptrFromInt(0);
    last_encoded = result;
    return result.ptr;
}

export fn getEncodedSize() u32 {
    if (last_encoded) |buf| return @intCast(buf.len);
    return 0;
}

export fn freeEncoded() void {
    if (last_encoded) |buf| {
        allocator.free(buf);
        last_encoded = null;
    }
}

export fn decodeSprites(bytes_ptr: [*]const u8, bytes_len: u32) u32 {
    if (last_decoded) |*d| {
        d.deinit(allocator);
        last_decoded = null;
    }

    const result = decode(allocator, bytes_ptr[0..bytes_len]) catch return 0;
    last_decoded = result;
    return @intCast(result.sprites.len);
}

export fn getDecodedPaletteSize() u32 {
    if (last_decoded) |d| return @intCast(d.palette.len);
    return 0;
}

export fn getDecodedPalettePtr() [*]allowzero const u32 {
    if (last_decoded) |d| return d.palette.ptr;
    return @ptrFromInt(0);
}

export fn getDecodedSpriteWidth(index: u32) u32 {
    if (last_decoded) |d| {
        if (index < d.sprites.len) return @intCast(d.sprites[index].width);
    }
    return 0;
}

export fn getDecodedSpriteHeight(index: u32) u32 {
    if (last_decoded) |d| {
        if (index < d.sprites.len) return @intCast(d.sprites[index].height);
    }
    return 0;
}

export fn getDecodedSpriteDataPtr(index: u32) [*]allowzero const u8 {
    if (last_decoded) |d| {
        if (index < d.sprites.len) return d.sprites[index].data.ptr;
    }
    return @ptrFromInt(0);
}

export fn freeDecoded() void {
    if (last_decoded) |*d| {
        d.deinit(allocator);
        last_decoded = null;
    }
}
