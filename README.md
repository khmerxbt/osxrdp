# osxrdp - xrdp for macOS
<h6>English | <a href="README_ko.md">한국어</a></h6>

## Overview
osxrdp is an unofficial module of xrdp to support rdp server in macOS.
<img width="1282" height="832" alt="OSXRDP" src="https://github.com/user-attachments/assets/539b2870-b5c6-4d16-90b0-ad6d2799951a" />

<h6><a href="https://www.youtube.com/watch?v=ltxx2bha5-8">Video</a></h6>

## Features
|Features|Status|
|------|---|
|Smooth Remote Control (H.264)|✅|
|Virtual monitor (for dynamic resolution)|✅|
|Remote control for non logoned macOS user|✅|
|Basic Clipboard (Text)|✅|
|Advanced Clipboard (Image, Rich Text)|✅|
|Multiple monitor (only H.264)|✅|
|File transfer| ✅ |
|Audio (user session, macOS 13+)|✅ PCM; local suppression requires macOS 14.2+|


## Manual
<h6><a href="Manual.md">Link</a></h6>

## Supported OS
macOS 12.4 or higher version.\
Support Apple Silicon & Intel mac.

## Etc
osxrdp is based on xrdp v0.10.6.1. \
To improve H.264 video quality on macOS, I made a few adjustments to the encoder settings. The corresponding changes can be found in scripts/xrdp_patch.patch.


## This contribution

**The fixes in this contribution are 100% AI-coded using OpenAI Codex**, with requirements and device testing supplied by the human contributor. Existing upstream code retains its original authorship.

See the [consolidated fixes](docs/LOCAL-FIXES.md), [known issues and compatibility limits](docs/KNOWN-ISSUES.md), and [regression tests](tests/README.md). The tested iPad still requires disconnect/reconnect for resolution changes; live resizing is not claimed as fixed.

The server changes require rebuilding XRDP 0.10.6.1. Apply `scripts/apply_xrdp_patches.sh /path/to/fresh/xrdp-0.10.6.1` before building; the script applies the core patch and the separate bundled-librfxcodec ARM64 optimization. It does not install binaries or modify a running service.
