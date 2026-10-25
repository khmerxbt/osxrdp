# Consolidated macOS and iPad session fixes

Based on upstream commit `5563d79`. Local test builds through 2.3.9 were accepted on 25 October 2026. The upstream application version is deliberately unchanged in this source contribution.

## AI authorship disclosure

**All new and modified code in this contribution was 100% AI-coded using OpenAI Codex.** The human contributor supplied requirements, approved local installations and permissions, tested the Mac/iPad behavior, and accepted the results. This statement applies to this contribution; existing upstream code retains its original authorship.

## Desktop and permissions

- Show the control window on launch/reopen and retain the original menu-bar icon without an added text label.
- Navigate to the appropriate Accessibility and Screen Recording settings. Request ScreenCaptureKit access to register the running app when needed; do not edit or reset the permission database.
- Check Retina backing pixels as well as logical dimensions, with orientation-independent scaling detection.
- Keep physical display outputs enabled and restore their original arrangement after virtual sessions, avoiding the black-screen failure previously requiring a cable reconnect.
- Cover physical displays with nonactivating black panels while the remote virtual display is active. Keep applications running and remove the covers on disconnect.
- Move accessible application windows into the remote logical work area and restore saved frames on disconnect, including an available-display fallback after unplugging a monitor. Handle OSXRDP-owned windows through AppKit.

## Audio

- Capture system audio once per user session through ScreenCaptureKit and convert supported planar/interleaved float or signed PCM to bounded stereo PCM packets.
- Add RDPSND negotiation, training, WAVE2 output, static-channel fragmentation, acknowledgements and congestion limits. Include system-audio permission metadata.
- After the RDP audio client is ready, use a private Core Audio tap/aggregate route to suppress local hardware playback while sending the ScreenCaptureKit mix remotely. Stop/disconnect destroys that route; default output and persistent volume/mute settings are untouched.

## Frame delivery and server patches

- Honor capture rates up to 60 fps for bitmap/RFX instead of the previous 30 fps cap; preserve short XRDP wait deadlines.
- Accelerate ARM64 RemoteFX tile packing with output identical to the scalar reference.
- Add an optional bundled-librfxcodec patch accelerating the first Progressive wavelet stage with ARM NEON. The scalar fallback and compression quality settings are retained.
- Add bounded display-control DATA_FIRST reassembly, complete-message length checks and channel diagnostics. Implement asynchronous module resize lifecycle handling, including capture failure completion and retained privacy/audio state. These are tested groundwork, **not a fix for the observed missing live iPad resize request**.
- Keep the established sRGB conversion; add periodic capture/render measurements to distinguish packing from later encoding/flow-control waits.

## Installer

Create the TLS private key with a restrictive umask and enforce mode 0600. This source contribution excludes local ad hoc trust exceptions, host-specific code hashes, certificates, runtime pins, installer binaries and the local version-number changes. The normal upstream IPC signing rule is retained.

## Results and review references

The tester confirmed the original icon, iPad-only audio, remote window transfer and local-screen privacy. After installing local build 2.3.9, the tester reported playback and animation were “much smoother.” Installed payload/ownership and runtime identity checks passed on the local deployment.

The isolated Retina Progressive benchmark fell from 17.33 to 12.64 ms/frame for synthetic simple motion (about 27% less compression time), with identical compressed streams. This is not a 27% end-to-end improvement or a client frame-rate measurement. See [performance investigation](RESIZE-PERFORMANCE.md), [known issues](KNOWN-ISSUES.md), and [test instructions](../tests/README.md).
