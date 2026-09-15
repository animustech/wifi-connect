# wifi-connect

## Deployment target

This repo is developed as a component of **loci-on-balena** (submodule there), which ships as a container running on a **Raspberry Pi 5**. Keep that target in mind for anything touching networking, container config, or architecture-specific behavior.

## Build & test: Docker Desktop only — no local Rust toolchain

The dev host has no `cargo`/`rustc` installed, and none should be installed. **Never suggest or run `rustup`/`cargo install` on the host.** All builds/tests go through Docker Desktop (already set up, context `desktop-linux`, daemon `linux/arm64` — matches the Rpi5 target natively, no QEMU needed).

Standard pattern — define once per shell session, reuse everywhere:

```bash
dc_cargo() {
    docker run --rm \
        -v "$(pwd)":/usr/src/app -w /usr/src/app \
        -v wifi-connect-cargo-registry:/usr/local/cargo/registry \
        -v wifi-connect-cargo-git:/usr/local/cargo/git \
        rust:1.76-bullseye \
        "$@"
}
```

- `rust:1.76-bullseye` matches CI's toolchain (`rust_toolchain: 1.76` in `.github/workflows/flowzone.yml`) and the `debian:bullseye` runtime base in `Dockerfile.template`.
- `Cargo.lock` is committed and CI-validated — don't run `cargo update`; `dc_cargo cargo build` resolves against the locked versions.
- The repo's own `Dockerfile.template` does **not** build from source — it downloads prebuilt release binaries from `balena-os/wifi-connect` GitHub releases. It's not usable as-is for testing local source changes; use `dc_cargo` for that instead.
- For anything that needs real Linux behavior the macOS host doesn't have (`/sys/class/net`, `ip`, D-Bus/NetworkManager), run it inside a container too — e.g. `nicolaka/netshoot` for quick network-namespace checks via `--network bridge` vs `--network none`. Don't assume host (macOS) behavior matches target (Linux) behavior.
- Full behavioral verification of anything touching real NetworkManager/WiFi hardware ultimately needs a real Linux host with NetworkManager and WiFi (ideally the actual Rpi5 target) — Docker Desktop on this Mac has no wireless NIC to exercise.

## Workflow

- Specs: `docs/specs/`. Plans: `docs/plans/`.
- `README.md` is the public-facing doc — don't restructure it casually; add new `docs/*.md` files for deeper internal explanations instead.
