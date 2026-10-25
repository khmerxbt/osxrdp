# Live resize and frame-delivery investigation after 2.3.7

Current status (2026-10-25): 2.3.9 is installed and verified. The user confirms much smoother playback and animation. Live resizing remains unresolved and is deferred at the user’s request.

## Accepted baseline and preservation

The fixes accepted through 2.3.7 are logged in `LOCAL-FIXES.md`. A local patch snapshot, extra source files, accepted installer and checksums were saved outside the repository before this investigation. This document records the local investigation used to prepare the source contribution.

## Baseline observations

An iPad Pro 12.9 using Windows App requested a 2732×1960 Retina session. After rotation the Mac still captured 2732×1960; the module received no resize request in the existing logs. A fresh portrait connection had previously worked.

The iPad advertises AVC-disabled graphics capabilities, so the server correctly selects RemoteFX Progressive even though H.264 is preferred and available. This matches the XRDP project's documented mobile-client limitation; forcing H.264 would violate the advertised capabilities. See [XRDP's H.264 compatibility notes](https://github.com/neutrinolabs/xrdp/wiki/H.264-encoding). Microsoft documents iPadOS dynamic resolution support separately in its [client feature comparison](https://learn.microsoft.com/en-us/previous-versions/remote-desktop-client/compare-remote-desktop-clients).

A 12-second read-only shared-memory sample during the user's video/rotation test recorded produced frames per second of 43, 50, 36, 40, 41, 43, 37, 29, 20, 24, 31, 37 (mean 35.9). The ring reached its seven-slot limit. These are production/consumption counters, not a measurement of the iPad's actual presentation rate. A short local-network probe showed no packet loss and round-trip latency averaging about 10 ms, with a maximum around 48 ms; it does not exclude bandwidth contention or later jitter.

## Changes in the 2.3.8 candidate

- Replace XRDP's empty display-control `data_first` callback with bounded reassembly and dispatch. A valid layout sent entirely as DATA_FIRST, or split across DATA_FIRST/DATA, must reach the existing layout parser. Add complete-length validation and diagnostics for channel creation, capabilities and fragment arrival. **The current evidence has not established that the iPad sends this fragment form. Live rotation remains unverified.**
- Preserve shorter core wait deadlines instead of overwriting every timeout with 100 ms. Keep the existing 100 ms ceiling for idle polling.
- Use ARM NEON deinterleaving for RemoteFX tile packing, with a scalar tail for partial edge tiles. Pixel values and compression settings are unchanged. A local 2732×1960 full-frame packing benchmark improved from 3.350 to 1.677 ms/frame. This isolates packing; it excludes compression, network transport and client decoding and does not prove a twofold end-to-end improvement.
- Keep the physical-screen covers, original saved window positions, display-sleep assertion and local sound suppression across capture recreation during a resize. Final disconnect still restores the local session. Do not disable physical outputs.
- Add periodic local capture and render metrics: incoming frame rate, callback cost, submitted frames, merged/skipped frames, in-flight count, packing cost and completion time. Module completion time includes encoder/flow-control waiting; it is not a direct client presentation latency measurement.
- Normalize active frame-interval configuration entries during local packaging so repeated package preparation does not duplicate them or treat commented `code=20` as active configuration.

## Validation and remaining work

- ARM64 module/GUI builds; real resize callback/IPC tests for landscape, portrait, invalid requests, graphics ordering and failure completion; preservation of immediate/short core deadlines.
- ASan/UBSan display-control tests cover ordinary messages, complete DATA_FIRST, every one of 655 split points, byte-at-a-time fragments, malformed/oversized/interleaved input and 100,000 generated sequences.
- Production RemoteFX packing is byte-identical to the scalar reference for all 4096 combinations of tile widths/heights from 1 through 64, padded source rows and guarded destinations.
- The combined server patch applies cleanly to XRDP v0.10.6.1 and reproduces the built source. It retains the project's OpenH264 quality/range settings.
- The rebuilt server negotiates verified TLS 1.2 and TLS 1.3 on an isolated loopback listener without interrupting the installed session. Its OpenH264 wrapper encodes landscape, portrait and Retina dimensions, and an independent FFmpeg decoder reads the test stream successfully.
- The active iPad session was left intact during development. Live rotation, continuous local privacy through resize, and before/after perceived video/animation smoothness require testing the installed candidate. Do not describe either remaining user issue as resolved before that check.

## Installed 2.3.8 result (2026-10-25)

The user installed and tested 2.3.8 and reported both remaining issues unchanged. Installation verification passed. Do not count this release as a live-resize or perceived-smoothness fix.

The display-control channel opened successfully and its capabilities were sent successfully. No normal DATA or DATA_FIRST callback was recorded after the user's rotation. Capture remained 2732×1960 backing pixels / 1366×980 logical points. The reassembly repair is independently tested, but this client test did not exercise it. Investigate the Windows App display mode/version before further server resize changes: the server cannot infer the client's new dimensions from silence.

Five-second capture samples ranged approximately 25–54 fps, with callback cost about 2–3 ms. Render submission samples ranged approximately 16–46 fps. Packing was usually 1–3 ms; module submission-to-release averaged roughly 22–62 ms, with outliers up to 490 ms. Release includes encoding and flow-control waits and is not a direct measure of client presentation. These samples are workload-dependent, not a controlled before/after benchmark.

An isolated Retina-size progressive encoder benchmark (same dimensions, tile layout and standard quantization) measured about 17 ms/frame for an animated gradient and 104 ms/frame for changing random noise. Noise is deliberately an extreme case, not representative video. A sample of the isolated gradient benchmark attributed about 59% of encoding samples to the scalar wavelet transform, 27% to entropy encoding and 12% to coefficient difference counting. Profiling excluded the benchmark's input generation. This establishes CPU compression work worth optimizing; it does not exclude client decoding, transport or ACK pacing as additional limits. No codec quality settings have been reduced.

## 2.3.9 compression candidate

Profiling led to an AArch64 NEON implementation of the first vertical Progressive wavelet stage. It processes eight independent columns at once, retaining the original lifting arithmetic and reduce-extrapolate boundary conditions. Other platforms keep the existing scalar code. The separate `scripts/librfxcodec_neon.patch` targets the bundled codec, not OSXRDP's tile-packing code.

On this M4, the same synthetic animated-gradient benchmark measured 17.33 ms/frame scalar versus 12.64 ms/frame accelerated (about 27% less compression time). Extreme changing noise measured 102.75 versus 98.24 ms/frame. Encoded byte counts and full-stream hashes matched in both cases. Ten thousand transform comparisons, including all constant input values and generated quantization tables, passed with identical coefficient buffers, scratch buffers and boundary guards under AddressSanitizer. These are isolated CPU results, not proof of smooth video on the iPad.

The user also confirmed that Windows App has no Automatic/Dynamic display option and that changing to 1772×1271 while remaining in landscape does not change the active remote display. Microsoft's [iPadOS display settings documentation](https://learn.microsoft.com/en-us/windows-app/display-settings?tabs=windows) describes shared fixed presets; its dynamic-resolution discussion is in the external-display/Stage Manager section. This does not establish that every iPadOS mode lacks live resizing. The observed session sends no layout update, so reconnect remains necessary in this tested client mode. Do not infer a new size from pointer positions or forcibly alternate screen orientation on the host.

## Installed 2.3.9 acceptance (2026-10-25)

The user reported: “the playback and animation is much smoother” and requested that resizing be skipped. The 2.3.9 receipt, installed payload hashes, root ownership, server identity pin, exact module runtime constraint and private TLS key mode were verified after this test. Performance work is accepted on that basis; this is subjective installed-session acceptance, not a measured client presentation rate or a guarantee of 60 fps. Further live-resize investigation is deferred, with reconnect documented as the current requirement. No further installation is needed for this task.
