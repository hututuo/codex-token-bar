# Zstandard 1.5.7 source and license

The C decoder in `Sources/CZstd/zstddeclib.c` and public headers in
`Sources/CZstd/include/` are from the official
[facebook/zstd v1.5.7 release](https://github.com/facebook/zstd/releases/tag/v1.5.7).

Pinned source archive:

- URL: <https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz>
- SHA-256: `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`
- Release commit shown by GitHub: `f8745da`

The source archive checksum was verified locally. The decoder amalgamation was
generated from the release's `build/single_file_libs/zstddeclib-in.c` using its
`combine.py` tool and the upstream command:

```sh
python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

The vendored decoder retains its upstream license header. Zstandard is offered
under either BSD-3-Clause or GPL-2.0-or-later; this project selects the
BSD-3-Clause terms in [`Zstandard-BSD-3-Clause.txt`](Zstandard-BSD-3-Clause.txt).
No zstd shared library, executable, Homebrew installation, or runtime download
is required: SwiftPM compiles the vendored C source into the application.

`CZstd.h` defines `ZSTD_STATIC_LINKING_ONLY` before including the upstream
header so Swift can import `ZSTD_FrameHeader` and `ZSTD_getFrameHeader`, along
with the public `ZSTD_DStream` and `ZSTD_decompressStream` APIs.
