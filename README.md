>[!NOTE]
>This toolchain is built specifically for the fern-tui team's internal use and is not intended for the `general public`.
>Please use it with caution. It is intentionally `minimal` and not under `active` development. Bug reports are welcome, but updates may be infrequent.
>Zig version `zig-x86_64-linux-0.17.0-dev.2320+1e770dbef` is used to build this project.

# zig-cache-manager (`zcm`)

A fast, zero-dependency CLI tool written in pure Zig for inspecting and pruning the Zig compiler's build cache.

## Why

`zig build` stores artifacts in `.zig-cache/` (local, per-project) and `~/.cache/zig` (global, shared across projects). These directories grow unbounded until you nuke them manually — and `rm -rf .zig-cache` is destructive if your project is still building. `zcm` gives you fine-grained control: preview before you delete, evict by age or size cap, or wipe surgically.

## Building & Testing

```bash
# Build the binary
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
