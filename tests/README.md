# Local regression tests

Run from the repository root on macOS. Display-control assembly is portable C:

```sh
clang -fsanitize=address,undefined -fno-omit-frame-pointer tests/test_display_control_fragments.c -o /tmp/test-display-control
/tmp/test-display-control
```

`test_rfx_tiles.cpp` links against a Release build of `libosxup.dylib` and checks all 4096 tile edge dimensions, padded source strides and destination guards. Pass `-IScreenMirrorLib`, the build product library directory with `-L`, and `-losxup`; make that directory available through `DYLD_LIBRARY_PATH` when running the test.

The display-control helper is also embedded as a new file in `scripts/xrdp_patch.patch`, which applies to XRDP v0.10.6.1. The locally generated patched source and the tested helper must match.

`test_progressive_dwt.c` compares the production Progressive wavelet transform against an unmodified scalar source from the same librfxcodec revision. Compile the original `src/rfxencode_dwt_shift_rem.c` with `-Drfx_encode_dwt_shift_rem=scalar_dwt`, compile the patched source normally, then link both objects with this test. Pass the codec's `src` directory with `-I`. Run with AddressSanitizer on Apple Silicon. It checks all constant byte values, random tiles and quantization tables, the entire coefficient/scratch buffers and boundary guards. The upstream scalar code shifts negative values, so its existing undefined-shift diagnostics must not be mistaken for regressions in the accelerated path.

`scripts/librfxcodec_neon.patch` applies with `patch -p1` **inside the librfxcodec directory** of the XRDP 0.10.6.1 release source, separately from `scripts/xrdp_patch.patch` at the XRDP source root. It accelerates only the first vertical transform on AArch64 and preserves the original scalar fallback. This targets the bundled codec submodule; an upstream PR should keep that dependency change separate from OSXRDP application fixes.


Run `./tests/run.sh` for the portable display-control and RDPSND tests with ASan/UBSan. To also exercise production module callbacks, run `./tests/run.sh /absolute/path/to/Release/products` on macOS after building the `osxup` scheme. The optional module tests cover tile edges/guards, RDPSND fragmentation/readiness and asynchronous resize callback/IPC ordering, invalid input and failure completion. They do not connect a client or rearrange displays.

Native ScreenCaptureKit conversion, Core Audio route restoration, virtual-display restoration and window movement were tested locally, followed by the human's installed iPad acceptance. Those integration fixtures required local permissions and are not included in the portable runner. The portable runner checks protocol parsing only; it does not establish macOS integration compatibility.
