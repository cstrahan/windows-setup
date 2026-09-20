# Vendored libghostty-vt

`ghostty-vt-small.wasm` is [libghostty-vt](https://mitchellh.com/writing/libghostty-is-coming)
compiled to WebAssembly: a terminal emulator (VT parsing, screen, scrollback, reflow, input
encoding) lifted out of [Ghostty](https://ghostty.org). The pty harness feeds it the byte stream
coming out of a ConPTY and reads the resulting screen back.

| | |
|---|---|
| Source | `https://github.com/ghostty-org/ghostty/releases/download/tip/ghostty-vt-small.wasm` |
| Upstream commit | `a3010543b0c39b98a81ace9f50b1910ae641c8c1` (main) |
| Built | 2026-09-18, fetched 2026-09-19 |
| SHA-256 | `D258994EDD54098A20404E099159DD5A1903E6E3D5172C345537C469549B9F02` |
| Size | 747,017 bytes |
| Signature | `ghostty-vt-small.wasm.minisig`, minisign, timestamp 1789753151 |
| Licence | MIT, as Ghostty |

## Why it's committed rather than downloaded

There is no immutable URL for an official build. Ghostty publishes the wasm **only on the rolling
`tip` prerelease**, rebuilt on every commit to main, and tagged releases carry no wasm asset — so a
pinned hash against that URL would break the next time anyone pushes upstream, and a fresh install
months later would fail. libghostty-vt's own header says the C API "is not yet stable and is
definitely going to change", so pinning the exact build our bindings were written against is worth
a 747 KB file in git.

The alternative considered was the npm package `@wterm/ghostty` (immutable, built from tagged
v1.3.1). It was rejected after testing: it needs an `env::log` host import, and it's the older API.

`ghostty-vt.wasm` (1.0 MB) is the speed-optimised build of the same thing; the `-small` one is
10–20% slower and was chosen to keep the repository smaller. Both need the `simd128` feature,
which wasmtime enables by default.

## Updating it

1. Download the asset and its `.minisig` from the `tip` release.
2. Record the new commit, date, size and SHA-256 above.
3. Run the harness tests: the API is unstable, so expect the bindings to need work.

Once the zig/WASM toolchain workload exists, this can instead be built from a **tagged** source
tarball (`libghostty-vt-source.tar.gz` ships on the same release), which removes the dependence on
a nightly asset entirely.
