# Known issues and validation limits

## Observed and unresolved

- **Live resolution/orientation changes in Windows App on iPadOS:** the tested session keeps its original size until a full disconnect/reconnect. The display-control channel opens and server capabilities are sent, but no layout DATA or DATA_FIRST reaches the server during the tested rotation or preset changes. Fresh portrait/landscape connections work. Further investigation was deferred by the tester. This contribution does not claim to fix automatic iPad resizing.


## Behavior and compatibility limits

- **High-motion performance is workload-dependent:** the tester reports much smoother playback and animation after the ARM64 Progressive compression optimization. This does not establish sustained 60 fps. The tested iPad advertises AVC-disabled capabilities and negotiates RemoteFX Progressive rather than H.264; the server respects those capabilities.

- Physical-screen covers provide visual privacy while sharing the signed-in desktop. They do not log out, lock the workstation, or create an isolated user session. Physical outputs stay enabled to avoid the previously observed black-screen/wake failure.
- Window transfer requires Accessibility permission and movable AX windows. Minimized windows are skipped until restored; apps that reject positioning or full-screen transitions may remain outside the remote work area. OSXRDP's own windows use AppKit instead of self-process Accessibility.
- System audio capture uses ScreenCaptureKit on macOS 13 or later. Suppression of local playback requires Core Audio process taps on macOS 14.2 or later and a successful private route. Earlier systems retain video support but do not provide the complete remote-only audio behavior. Lockscreen/legacy capture has no audio streaming.
- Audio uses 48 kHz stereo PCM with bounded queues; congested audio is dropped rather than building an unbounded delay. No microphone redirection is implemented.
- Screen Recording and Accessibility grants remain under macOS/user control. Installing a differently signed build may require renewed permission grants.
- The new work was built and exercised on an M4 Mac running macOS 27.0.1 with two physical monitors and Windows App on an iPad Pro 12.9. Intel, older supported macOS releases, other RDP clients and multi-monitor RFX have not received equivalent integration testing.
- Full-system sleep, Wake-on-LAN and unattended wake are not established by this testing. Display-sleep assertions during an active session do not prove a sleeping Mac can accept a connection.
- The resize callback/fragment assembly have regression tests, but live cover/audio continuity through a client-driven resize was not exercised by this iPad because no layout update arrived.
- The server/codec patches must be applied when rebuilding XRDP. Updating only the OSXRDP module does not install the Progressive encoder acceleration.

The tester accepted the current color rendering and closed further color work. No unresolved color correction is being proposed.
