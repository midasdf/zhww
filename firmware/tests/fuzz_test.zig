//! 壊れた入力に対する堅牢性のテスト（変異テスト / ファジングの一種）。
//!
//! **なぜ重要か**: 端末が受け取る PSBT やカードの中身は**外部から来る信頼できないデータ**である。
//! 解析器が落ちたり固まったりすると、最悪の場合は署名の途中で停止する
//! （[docs/05-threat-model.md] の 4-6「実装バグ」）。
//!
//! ここでは有効なデータを少しずつ壊して大量に流し込み、
//! 「**必ず解析に成功するか、エラーを返すかのどちらか**（落ちない・固まらない）」ことを確かめる。
//!
//! 乱数は固定の種を使う（失敗したときに再現できる）。Debug / ReleaseSafe では
//! 安全検査が有効なので、範囲外アクセスや整数オーバーフローもここで捕まる。

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const Fuzz = struct {
    prng: std.Random.DefaultPrng,

    fn init(seed: u64) Fuzz {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    /// **注意**: `std.Random` は乱数器を指すポインタを持つ。
    /// 構造体に保存して返すと、指し先（自分自身）がコピーされて**ダングリング**する。
    /// そのため使うたびに作る。
    fn random(self: *Fuzz) std.Random {
        return self.prng.random();
    }

    /// データを少し壊す（1〜8 箇所）。
    fn mutate(self: *Fuzz, data: []u8) void {
        const changes = 1 + self.random().uintLessThan(usize, 8);
        for (0..changes) |_| {
            if (data.len == 0) return;
            switch (self.random().uintLessThan(u8, 5)) {
                0 => data[self.random().uintLessThan(usize, data.len)] ^= @as(u8, 1) << @intCast(self.random().uintLessThan(u4, 8)),
                1 => data[self.random().uintLessThan(usize, data.len)] = self.random().int(u8),
                2 => {
                    // 途中で切る
                    const at = self.random().uintLessThan(usize, data.len);
                    data[at] = 0;
                },
                3 => {
                    // 端を壊す
                    if (self.random().boolean()) {
                        data[0] = self.random().int(u8);
                    } else {
                        data[data.len - 1] = self.random().int(u8);
                    }
                },
                else => {
                    // 2 バイトを入れ替える
                    const a = self.random().uintLessThan(usize, data.len);
                    const b = self.random().uintLessThan(usize, data.len);
                    const tmp = data[a];
                    data[a] = data[b];
                    data[b] = tmp;
                },
            }
        }
    }
};

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const out = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    try decoder.decode(out, encoded);
    return out;
}

test "PSBT: 壊れた入力を与えても落ちない（2000 件の変異）" {
    const vectors = @embedFile("vectors/core_psbt.json");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const base64 = parsed_json.value.object.get("unsigned_psbt_base64").?.string;
    const valid = try decodeBase64(allocator, base64);

    var fuzz = Fuzz.init(0x5EED_1234);
    var ok: usize = 0;
    var failed: usize = 0;

    for (0..2000) |_| {
        var iteration = std.heap.ArenaAllocator.init(testing.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();

        const mutated = try a.dupe(u8, valid);
        fuzz.mutate(mutated);

        const result = zhww.btc_psbt.Psbt.parse(a, mutated);
        if (result) |psbt| {
            ok += 1;
            // 解析できたものは、もう一度書き出して読み直せること（往復）
            const sigs = try a.alloc([]const zhww.btc_psbt.PartialSig, psbt.inputs.len);
            for (sigs) |*s| s.* = &.{};
            const serialized = try zhww.btc_psbt.Psbt.serialize(a, psbt, sigs);
            const reparsed = try zhww.btc_psbt.Psbt.parse(a, serialized);
            try testing.expectEqual(psbt.inputs.len, reparsed.inputs.len);
            try testing.expectEqual(psbt.outputs.len, reparsed.outputs.len);
            try testing.expectEqual(psbt.unsigned_tx.inputs.len, reparsed.unsigned_tx.inputs.len);
            try testing.expectEqual(psbt.unsigned_tx.outputs.len, reparsed.unsigned_tx.outputs.len);
        } else |_| {
            failed += 1;
        }

        // 病的な確保をしていないこと（1 件あたり 1MB 未満）
        try testing.expect(iteration.queryCapacity() < 1024 * 1024);
    }

    // 変異の大半は解析に失敗するはず（＝検査が効いている）
    try testing.expect(failed > ok);
    try testing.expect(ok + failed == 2000);
    std.debug.print("\n  PSBT: 解析成功 {d} / 失敗 {d}\n", .{ ok, failed });
}

test "トランザクション: 壊れた入力を与えても落ちない" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 適当なトランザクションを作ってから壊す
    const inputs = try allocator.alloc(zhww.btc_transaction.TxIn, 2);
    inputs[0] = .{ .prevout = .{ .txid = @splat(0x11), .vout = 0 }, .script_sig = &.{}, .sequence = 0xFFFFFFFF, .witness = &.{} };
    inputs[1] = .{ .prevout = .{ .txid = @splat(0x22), .vout = 1 }, .script_sig = &.{}, .sequence = 0, .witness = &.{} };
    const outputs = try allocator.alloc(zhww.btc_transaction.TxOut, 1);
    outputs[0] = .{ .value = 1000, .script_pubkey = &[_]u8{ 0x00, 0x14 } };
    const tx = zhww.btc_transaction.Transaction{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .has_witness = false,
    };
    const bytes = try tx.serialize(allocator, false);

    var fuzz = Fuzz.init(0xABCD_5678);
    var ok: usize = 0;
    var failed: usize = 0;

    for (0..1000) |_| {
        var iteration = std.heap.ArenaAllocator.init(testing.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();

        const mutated = try a.dupe(u8, bytes);
        fuzz.mutate(mutated);

        if (zhww.btc_transaction.Transaction.parse(a, mutated)) |parsed_tx| {
            ok += 1;
            // 往復して同じ形になること
            const again = try parsed_tx.serialize(a, parsed_tx.has_witness);
            const reparsed = try zhww.btc_transaction.Transaction.parse(a, again);
            try testing.expectEqual(parsed_tx.inputs.len, reparsed.inputs.len);
            try testing.expectEqual(parsed_tx.outputs.len, reparsed.outputs.len);
            try testing.expectEqual(parsed_tx.version, reparsed.version);
        } else |_| {
            failed += 1;
        }
        try testing.expect(iteration.queryCapacity() < 1024 * 1024);
    }

    try testing.expect(ok + failed == 1000);
    std.debug.print("  Transaction: 解析成功 {d} / 失敗 {d}\n", .{ ok, failed });
}

test "UR / Bytewords: 壊れた文字列を拒否する" {
    var fuzz = Fuzz.init(0x0BAD_F00D);
    const alphabet = "ur:bytes/1-2/lpadacslbcyfmemqdoshdcxjojkidjyzmadaegmaoaeaeaeadswmuoygamogscfkodwknsrmdvwkttlfsfnluwysewzlubg-ZZ00";

    for (0..500) |_| {
        var iteration = std.heap.ArenaAllocator.init(testing.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();

        const length = 1 + fuzz.random().uintLessThan(usize, 60);
        const text = try a.alloc(u8, length);
        for (text) |*c| c.* = alphabet[fuzz.random().uintLessThan(usize, alphabet.len)];

        // 解析できてもできなくてもよいが、落ちてはいけない
        if (zhww.ur.parse(text)) |uri| {
            try testing.expect(uri.ur_type.len <= zhww.ur.max_type_len);
        } else |_| {}

        // パートとして読む経路も試す
        var part_buffer: [4096]u8 = undefined;
        if (zhww.ur.decodePartUr(&part_buffer, text)) |decoded| {
            try testing.expect(decoded.part.data.len <= part_buffer.len);
        } else |_| {}

        try testing.expect(iteration.queryCapacity() < 1024 * 1024);
    }
}

test "FAT32: でたらめな中身のデバイスを拒否する（落ちない・固まらない）" {
    const device_mod = zhww.block_device;
    var fuzz = Fuzz.init(0xFEED_BEEF);
    var mounted: usize = 0;
    var rejected: usize = 0;

    for (0..30) |_| {
        var iteration = std.heap.ArenaAllocator.init(testing.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();

        // 512 セクタ（256KB）のでたらめなデバイス
        const storage = try a.alloc(u8, 512 * 512);
        for (storage) |*byte| byte.* = fuzz.random().int(u8);
        var device = device_mod.MemoryDevice.init(storage);

        if (zhww.fs_fat32.Fat32.mount(device.device(), a)) |mounted_fs| {
            mounted += 1;
            var fs = mounted_fs;
            // マウントできてしまった場合も、操作がエラーを返すだけで落ちないこと
            var iterator = fs.openDir("/") catch continue;
            var entry: zhww.fs_fat32.Entry = .{};
            var guard: usize = 0;
            while (iterator.next(&entry) catch break) {
                guard += 1;
                if (guard > 4096) break; // 固まらないことの確認
            }
        } else |_| {
            rejected += 1;
        }
        try testing.expect(iteration.queryCapacity() < 64 * 1024 * 1024);
    }

    std.debug.print("  FAT32: マウント成功 {d} / 拒否 {d}\n", .{ mounted, rejected });
    try testing.expect(rejected > 0); // でたらめな中身はほぼ必ず拒否される
}

test "EVM: 壊れた raw トランザクションを拒否する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw_hex = "02f86f0107843b9aca008506fc23ac0082520894353535353535353535353535353535353535353584075bcd1580c080a08b29bfd611a0f695677f38218b2a6d02218f906adedbb1f171aa49b261794de2a02e5c9604faa6d3f48c89f8568aa04ea6cef7e058d0464ef4447989524c1bd4cf";
    const valid = try allocator.alloc(u8, raw_hex.len / 2);
    _ = try std.fmt.hexToBytes(valid, raw_hex);

    var fuzz = Fuzz.init(0x1234_5678);
    var ok: usize = 0;
    var failed: usize = 0;

    for (0..500) |_| {
        var iteration = std.heap.ArenaAllocator.init(testing.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();

        const mutated = try a.dupe(u8, valid);
        fuzz.mutate(mutated);

        if (zhww.evm_transaction.decode(a, mutated)) |decoded| {
            ok += 1;
            // 壊れた入力でも、返ってきた値の整合性が保たれていること
            if (decoded.to) |to| try testing.expectEqual(@as(usize, 20), to.len);
            try testing.expect(decoded.data.len <= mutated.len);
        } else |_| {
            failed += 1;
        }
        try testing.expect(iteration.queryCapacity() < 1024 * 1024);
    }

    try testing.expect(ok + failed == 500);
    std.debug.print("  EVM: 解析成功 {d} / 失敗 {d}\n", .{ ok, failed });
}

test "BIP39: でたらめな mnemonic を拒否する" {
    const words = [_][]const u8{ "abandon", "about", "zoo", "notaword", "", "A", "日本語" };
    var fuzz = Fuzz.init(0x9999_1111);
    var accepted: usize = 0;
    var rejected: usize = 0;

    for (0..300) |_| {
        var iteration = std.heap.ArenaAllocator.init(testing.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();

        var list = std.ArrayList(u8).empty;
        const count = 1 + fuzz.random().uintLessThan(usize, 30);
        for (0..count) |i| {
            if (i > 0) try list.append(a, ' ');
            try list.appendSlice(a, words[fuzz.random().uintLessThan(usize, words.len)]);
        }

        var seed: [64]u8 = undefined;
        if (zhww.bip39.mnemonicToSeed(&seed, list.items, "")) |_| {
            accepted += 1;
        } else |_| {
            rejected += 1;
        }
        try testing.expect(iteration.queryCapacity() < 1024 * 1024);
    }

    std.debug.print("  BIP39: 受理 {d} / 拒否 {d}\n", .{ accepted, rejected });
    try testing.expect(rejected > accepted);
}
