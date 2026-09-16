# Vendored third-party sources

The freestanding KyanOS runtime needs a JavaScript engine that
runs without a host libc. We vendor [QuickJS-NG][1] for that role.

## Fetching

```sh
cd runtime/freestanding/third_party
./fetch_quickjs.sh           # latest pinned version (0.5.0)
./fetch_quickjs.sh 0.6.0     # or pick a version
```

The script downloads the upstream tarball, extracts the C sources +
generated atom/opcode tables, and copies them into
`third_party/quickjs/`. The build script (`runtime/freestanding/build.zig`)
picks them up from there.

## License

QuickJS-NG ships under MIT. The bundled `LICENSE` file is preserved
in `third_party/quickjs/LICENSE` after fetching.

## Why not Bun / V8 / SpiderMonkey?

Bun and V8 both need a host libc + thread library; no good way to
boot them on a kernel that doesn't yet have those. SpiderMonkey is
the same plus a Rust toolchain. QuickJS is a self-contained ~70 KLOC
of C with a carefully limited libc dependency surface — `host_shim.zig`
provides the dozen or so shim functions (`malloc`, `free`, `memcpy`,
`__assert_fail`, `clock_gettime`) it actually calls.

[1]: https://github.com/quickjs-ng/quickjs
