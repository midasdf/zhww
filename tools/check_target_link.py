#!/usr/bin/env python3
"""Pinned, offline ARM Secure/NS link harness. NOT bootable firmware or stack proof.

The first --fetch downloads a SHA256-pinned source archive. Every build checks the
archive and extracts fresh sources. No host libsecp256k1, SDK, heap or stdio is linked.
Zig emits optimized LLVM IR; Zig's Clang lowers it with per-function stack metadata.
"""
# SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
# SPDX-License-Identifier: MIT
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

from check_memory_layout import read_layout
from target_elf import Elf, check_image
from fatal_entry_check import check_fatal_entry

ROOT = Path(__file__).resolve().parents[1]
FIRMWARE = ROOT / "firmware"
TARGET = FIRMWARE / "target"
SECURE_FLASH = (0x10000000, 0x10100000)
NS_FLASH = (0x10100000, 0x10200000)
SECURE_RAM = (0x20000000, 0x2006e000)  # 440 KiB, candidate mapping only
NS_RAM = (0x2006e000, 0x20082000)      # 80 KiB; no SAU/MPU setup here


def verified_archive(data, expected):
    if len(data) > 8 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("secp256k1 archive checksum/size mismatch")


def extract_sources(archive, destination, expected_root):
    """Reject links, traversal, special files and oversized archive expansion."""
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        if len(members) > 10000 or sum(m.size for m in members) > 32 * 1024 * 1024:
            raise ValueError("Source archive expansion limit")
        seen = set()
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or not path.parts or
                    path.parts[0] != expected_root or str(path) in seen or member.size < 0 or
                    not (member.isdir() or member.isfile())):
                raise ValueError("Unsafe source archive member")
            seen.add(str(path))
        # Checked regular files/directories only; use manual extraction across Python versions.
        for member in members:
            path = destination.joinpath(*PurePosixPath(member.name).parts)
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                stream = source.extractfile(member)
                if stream is None:
                    raise ValueError("Missing source member")
                with stream, path.open("xb") as out:
                    out.write(stream.read())
    return destination / expected_root


def run(zig, *args):
    subprocess.run([zig, *map(str, args)], cwd=FIRMWARE, check=True)


def symbol_u32(elf, name):
    symbols = [s for s in elf.symbols if s.name == name]
    if len(symbols) != 1 or symbols[0].size != 4 or symbols[0].info != 0x11:
        raise ValueError(f"Invalid {name} symbol")
    symbol = symbols[0]
    if not 0 < symbol.section < len(elf.sections):
        raise ValueError("Context constant must have a real section")
    section = elf.sections[symbol.section]
    offset = symbol.value - section.address
    if section.kind != 1 or offset < 0 or offset + 4 > section.size:
        raise ValueError("Context constant outside PROGBITS")
    return struct.unpack("<I", elf.region(section.offset + offset, 4))[0]


def build(zig, archive, output, manifest, host_tests=False, optimize="ReleaseSafe"):
    with tempfile.TemporaryDirectory(prefix="zhww-target-") as temp:
        directory = Path(temp)
        source = extract_sources(archive, directory, "secp256k1-" + manifest["secp256k1"]["commit"])
        definitions = ["-D" + d for d in manifest["c_defines"]]
        # sizeof opaque C context for selected target ABI; do not execute ARM code to obtain it.
        wrapper = directory / "secp_with_size.c"
        wrapper.write_text('#include ' + json.dumps(str(source / "src/secp256k1.c")) +
                           '\nconst unsigned int zhww_target_context_bytes = sizeof(secp256k1_context);\n')
        objects = []
        for name, file in (("secp256k1", wrapper),
                           ("precomputed_ecmult", source / "src/precomputed_ecmult.c"),
                           ("precomputed_ecmult_gen", source / "src/precomputed_ecmult_gen.c")):
            obj = output / (name + ".o")
            run(zig, "cc", "-target", "thumb-freestanding", "-mcpu=cortex_m33", "-Os",
                "-ffunction-sections", "-fdata-sections", "-fstack-size-section",
                "-I", TARGET / "include", "-DUSE_EXTERNAL_DEFAULT_CALLBACKS=1",
                *definitions, "-c", file, "-o", obj)
            objects.append(obj)
        # Backend stack metadata is not emitted by Zig's -fstack-report on this toolchain.
        # Lower emitted IR with the SAME bundled compiler rather than inventing stack sizes.
        ir = output / "secure.ll"
        run(zig, "build-obj", "-target", "thumb-freestanding", "-mcpu=cortex_m33",
            "-O" + optimize, "-fno-strip", "--dep", "zhww", "-Mroot=target/secure_link.zig",
            "-Mzhww=src/root.zig", "-fno-emit-bin", "-femit-llvm-ir=" + str(ir))
        zig_obj = output / "secure_zig.o"
        run(zig, "cc", "-target", "thumb-freestanding", "-mcpu=cortex_m33", "-Os",
            "-fstack-size-section", "-c", ir, "-o", zig_obj)
        secure_path = output / "secure-link-only.elf"
        run(zig, "build-exe", "target/link_runtime.zig", "-target", "thumb-freestanding",
            "-mcpu=cortex_m33", "-OReleaseSmall", "-fno-strip", "-fno-entry",
            "-Ttarget/secure.ld", zig_obj, *objects, "-femit-bin=" + str(secure_path))
        ns_path = output / "nonsecure-link-only.elf"
        run(zig, "build-exe", "target/nonsecure_link.zig", "-target", "thumb-freestanding",
            "-mcpu=cortex_m33", "-OReleaseSmall", "-fno-strip", "-fno-entry",
            "-Ttarget/nonsecure.ld", "-femit-bin=" + str(ns_path))
        inventory = directory / "inventory.o"
        run(zig, "build-obj", "memory_layout.zig", "-target", "thumb-freestanding",
            "-mcpu=cortex_m33", "-OReleaseSmall", "-femit-bin=" + str(inventory))
        layout = read_layout(inventory.read_bytes())
        secure, ns = Elf(secure_path.read_bytes()), Elf(ns_path.read_bytes())
        secure_report = check_image(secure, SECURE_FLASH, SECURE_RAM, {
            ".secure_workflow": layout["workflow"], ".secure_workspace": layout["workspace"],
            ".secure_framebuffer": layout["framebuffer"], ".stack": layout["stack_reserve"],
            ".hal_reserve": layout["hal_reserve"], ".fault_stack": layout["fault_stack_reserve"],
        })
        ns_report = check_image(ns, NS_FLASH, NS_RAM, {".nonsecure_ingress": layout["ingress"], ".stack": layout["nonsecure_stack_reserve"]})
        required = {"zhww_link_only_prepare", "zhww_link_only_render", "zhww_link_only_sign",
                    "zhww_target_fatal_enter", "zhww_target_fatal_wipe",
                    "secp256k1_context_preallocated_create", "secp256k1_context_randomize",
                    "secp256k1_context_preallocated_destroy", "secp256k1_ecdsa_sign", "secp256k1_ecdsa_verify"}
        if not required.issubset(s.name for s in secure.symbols if s.info & 15 == 2 and
                                0 < s.section < len(secure.sections) and
                                secure.sections[s.section].flags & 4):
            raise ValueError("Signing/rendering/context reachability was discarded")
        if any(s.name.startswith("secp256k1_") for s in ns.symbols):
            raise ValueError("Crypto linked into NS harness")
        check_fatal_entry(secure)
        context_size = symbol_u32(secure, "zhww_target_context_bytes")
        if not 0 < context_size <= 4096:
            raise ValueError("Target C context exceeds owned backing capacity")
        frames = secure.frames()
        if not frames or frames[0]["frame_bytes"] > layout["stack_reserve"]:
            raise ValueError("Single measured frame exceeds Secure stack reserve")
        (output / "stack-frames.json").write_text(json.dumps(frames, indent=2) + "\n")
        missing = sorted({s.name for s in secure.symbols if s.info & 15 == 2 and s.section and s.size and
                          s.value & ~1 not in {f["address"] for f in frames}})
        report = {"status": "offline_link_harness_NOT_bootable", "dependencies": manifest,
                  "zig_ir_optimize": optimize, "clang_lowering": "-Os -fstack-size-section",
                  "compiled_fatal_entry_tripwire": "passed; not hardware/runtime verification",
                  "secure": secure_report, "nonsecure": ns_report, "c_context_struct_bytes": context_size,
                  "stack": {"measured_functions": len(frames), "largest_frames": frames[:10],
                            "functions_without_metadata": missing,
                            "transitive_bound_proven": False},
                  "not_implemented": ["vectors/startup/boot metadata", "SAU/MPU/DMA/CMSE gateway",
                                      "target TRNG/display/button/SD HAL", "IRQ and transitive stack bound",
                                      "SDK integration", "signed update/recovery/OTP"]}
        if host_tests:
            # Same 32-bit arithmetic and table settings, executed on host ONLY.
            # Default callbacks/libc are used here, unlike the target fail-stop callbacks.
            host_objects = []
            for name in ("secp256k1", "precomputed_ecmult", "precomputed_ecmult_gen"):
                obj = output / (name + "-host.o")
                run(zig, "cc", "-Os", *definitions, "-c", source / f"src/{name}.c", "-o", obj)
                host_objects.append(obj)
            for mode in ("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"):
                run(zig, "test", "tests.zig", "-lc", *host_objects, "-O" + mode)
            report["selected_c_config_host_tests"] = "passed in all four Zig optimization modes; not ARM execution"
        (output / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--fetch", action="store_true", help="Allow first pinned source download")
    parser.add_argument("--archive", type=Path, help="Use an already downloaded pinned archive")
    parser.add_argument("--out", type=Path, default=FIRMWARE / "zig-out/target-link")
    parser.add_argument("--host-tests", action="store_true", help="Test selected C arithmetic/table config in all four modes")
    parser.add_argument("--optimize", choices=("ReleaseSafe", "ReleaseSmall"), default="ReleaseSafe",
                        help="Zig IR safety mode; ReleaseSafe retains bounds/overflow traps")
    args = parser.parse_args()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Invalidate prior success even if pin/download/argument validation later fails.
    (output / "report.json").unlink(missing_ok=True)
    manifest = json.loads((TARGET / "dependencies.json").read_text())
    version = subprocess.check_output([args.zig, "version"], text=True).strip()
    if version != manifest["zig"]:
        raise ValueError(f"Target harness requires pinned Zig {manifest['zig']}, got {version}")
    archive = args.archive or FIRMWARE / ".zig-cache/target-deps/secp256k1.tar.gz"
    if not archive.exists():
        if not args.fetch or args.archive:
            raise ValueError("Pinned archive unavailable; pass --fetch or --archive")
        with urllib.request.urlopen(manifest["secp256k1"]["url"], timeout=60) as response:
            data = response.read(8 * 1024 * 1024 + 1)
        verified_archive(data, manifest["secp256k1"]["sha256"])
        archive.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=archive.parent, prefix="download-") as temp:
            staged = Path(temp) / "archive.tar.gz"
            staged.write_bytes(data)
            staged.replace(archive) # atomic publication; concurrent builds never read partial data
    verified_archive(archive.read_bytes(), manifest["secp256k1"]["sha256"])
    report = build(args.zig, archive.resolve(), output, manifest, args.host_tests, args.optimize)
    print(json.dumps({"status": report["status"], "secure": report["secure"],
                      "nonsecure": report["nonsecure"], "c_context_struct_bytes": report["c_context_struct_bytes"],
                      "stack_measured_functions": report["stack"]["measured_functions"],
                      "largest_frame": report["stack"]["largest_frames"][0],
                      "transitive_stack_bound_proven": False, "report": str(output / "report.json")}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError) as exc:
        print(f"target link check failed: {exc}", file=sys.stderr)
        sys.exit(1)
