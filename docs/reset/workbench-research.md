# How Astropad Workbench gets its picture: research for Mirage's whole-display base

2026-10-28. Public sources, bundle metadata and a 40-second byte count on phrz's MacBook. No code was read, nothing was disassembled, and no traffic was decoded. **[Known]** means a source or an observation says so. **[Inference]** is my reading of it.

## 1. What is known

**The hybrid is HEVC plus a tile codec, picked by content.**
- [Known] Workbench has a Codec setting with three values: Automatic (the default), H.265 and Liquid. The choice depends "on the type of content, not your connection speed". H.265 is for large or frequent changes: scrolling, video, motion. Liquid is for small or rare changes: text editors, spreadsheets, design tools. Automatic combines the two "depending on what is happening on screen". [S1]
- [Known] Help > Vitals reports bandwidth for "H265 (HEVC)" and "Liquid (Tile)" separately, plus their sum. For HEVC it also counts keyframes and "recoveries", and a high recovery count means a poor link. [S2] Bundle resource `Contents/Resources/vitals/` holds an `index.html` with d3, so Vitals is a web view.
- [Known] LIQUID, as described by Astropad's CEO in April 2025 [S3, S4]:
  - The screen is cut into independent tiles, "typically 64×64 or 128×128 pixels".
  - Only changed tiles are encoded and sent.
  - There's no inter-frame prediction.
  - A lost packet damages only its own tile.
  - Tiling runs on the GPU.
  - It keeps "full fidelity, even at Retina resolutions", in contrast to encoders that discard colour information.
  - It's weak on full-screen motion: early versions dropped frames on video. That's why it became "a multi-codec system that switches dynamically", using traditional video for motion and tiles for drawing and text.
- [Known] Workbench 1.3 (Aug 2026) "rebuilt the streaming system for Apple silicon": 30% faster streaming, "faster refresh rates and sharper text", and content-aware encoding that treats text and images differently. [S5, S6]

**Transport**
- [Known] LIQUID runs over UDP. On loss or delay it "react[s] more quickly by sending more data". "Velocity Control" watches the network and adjusts how data is sent and prioritised. [S3]
- [Known] Workbench connects directly first. If it can't, it falls back to a TURN relay on its own. The stream is AES-256, and the codec choice doesn't depend on the path. [S2] 1.2.0 added NAT-PMP. [S7]
- [Known, observed] On this Mac the session is a **single UDP 5-tuple** to the host (172.16.66.98:51506 ↔ 172.16.66.206:49327). There's also a TCP connection to port 1883 (MQTT's port) on a cloud host, plus several idle UDP sockets, likely ICE candidates.
  - Data was sampled each second for 40 s. I don't know what phrz was doing at the time.
  - Downstream ranged from **3 KB/s to 709 KB/s**, averaging about **200 KB/s (1.6 Mbps)**. It was very bursty: several seconds at 3–30 KB/s, then bursts of 400–700 KB/s.
  - Upstream held steady at **3–20 KB/s**, which is feedback and input.
  - So on a 5 ms LAN Workbench is far from saturating the link. It sends almost nothing when still and bursts on change.

**Latency and frame rate**
- [Known] "End-to-end latency often under 16 milliseconds on a local network". [S3]
- [Known] Luna Display 3.0 in 2018, by camera, at 60 fps [S8]:
  - USB: 11.3 ms average, 16 ms median.
  - Wi-Fi: 22.4 ms average, 17 ms median.
  - It held 60 fps where Duet and Air Display didn't.
- [Known] Earlier, LIQUID used GPU acceleration on the Mac and ARM assembly on the iPad. [S9]

**Resolution**
- [Known] On connect, the host Mac **changes its display resolution to match the viewer's screen size and aspect ratio**, and restores it when the session ends. Astropad blames a blurry picture on the network, not on scaling. [S10] The press calls this a "unified virtual display". [S11]

**Bundle metadata** (version 1.4.0, build 1029, built 2026-10-26)
- [Known] One universal binary is both host and viewer. It links:
  - ScreenCaptureKit, VideoToolbox, CoreMedia and CoreVideo
  - IOSurface, Metal, CoreImage and QuartzCore
  - Network.framework
  - Vision, Speech and SceneKit
  - libswiftCompression and libswiftAccelerate
- [Known] Other contents:
  - A small `default.metallib` (27 KB).
  - Sparkle and Sentry frameworks.
  - Helper executables `wb`, `tmux` and `workbench-watchdog`.
  - Bonjour service `_astropad-workbench-p2p._tcp`.
  - The only entitlement is audio input.
- [Inference] Video uses Apple's hardware HEVC through VideoToolbox. The "Liquid (Tile)" path is Astropad's own code on Metal, with no third-party codec library: no x265, libvpx or ffmpeg is bundled.
- [Inference] Vision may be what 1.3's "content-aware encoding" uses to find text. It could just as well serve other features, so this is weak.
- [Inference] The Compression and Accelerate overlays hint at a general-purpose lossless step, such as LZ4 or zlib, after a tile transform.

## 2. What I infer about how it looks good

1. **Small changes never go through HEVC.** [Inference] Text, cursors and UI widgets change only a few 64–128 px tiles, and those go through an intra-only, colour-preserving tile codec with no 4:2:0 subsampling and no QP ramp. Text is sharp in the first frame it appears, so no "sharpening later" step is needed for typing. That is the main gap from Mirage, where in `wholeDisplayOnly` every change, typing included, goes through HEVC at the rate controller's QP ceiling and only sharpens after 300 ms of stillness.
2. **HEVC carries motion, chosen by region and moment.** [Inference] Vitals shows both codecs' bandwidth at once, so Automatic is a mix inside one session, probably per frame or per region, not a session-wide mode. Large changed areas go to HEVC, and the tile codec then repairs the area once it settles.
3. **One pixel per pixel.** The host resizes its display to the viewer's size. That removes the scaling blur and cuts the pixel count, which may matter as much as the codec.
4. **Quiet when still.** The idle floor is a few KB/s. There's no periodic refresh or keyframe stream, and loss recovery is per tile, or an HEVC "recovery" that isn't a full keyframe. [Inference: LTR or reference-invalidation style, since Vitals counts it apart from keyframes.]
5. **Loss is answered with redundancy, not waiting.** "Sending more data" suggests FEC or eager retransmission over one UDP flow. [Inference]

## 3. Testable lessons for Mirage's whole-display base

Mirage today, from `Sources/MirageHost/HEVCEncoder.swift`:
- HEVC Main, which is 8-bit 4:2:0. BGRA from ScreenCaptureKit is subsampled inside the encoder.
- Low-latency rate control, LTR, no frame reordering, no periodic keyframes.
- A QP-20 re-encode for sharpening on LAN.

Each lesson below has a test the planned gate can run.

1. **Route small changes to lossless tiles from the same capture, on every link.**
   - Keep one capture as the only source of truth. When a capture's changed area is under a threshold (start at about 5% of the display, or N tiles of 64 or 128 px), send those tiles lossless and skip the HEVC frame. Above the threshold, send HEVC, then repair with tiles when the area goes still.
   - Tiles and video carry the same capture sequence number and present atomically, so TRUTH still holds.
   - *Test:* typing in TextEdit and a blinking caret at full scale on the MacBook. Measure time-to-sharp (edge energy against the host truth reference) and bytes per keystroke, for `wholeDisplayOnly` versus tiles-for-small-changes versus Workbench in the side-by-side recorder.
   - *Expected:* tiles are sharp in frame 1, while HEVC needs 300 ms plus the re-encode.
2. **Chroma: test 4:2:0 against tiles on coloured text before reaching for 4:4:4 HEVC.**
   - The QP-20 sharpening frame is still 4:2:0, so red or blue text, and text on coloured backgrounds, stays fringed however low the QP.
   - *Test A:* render coloured text samples, then compare the 4:2:0 QP-20 frame and a lossless tile against the source by chroma PSNR and max error on glyph edges.
   - *Test B:* on mac-daddy's encoder, query `VTCopySupportedPropertyDictionaryForEncoder` and try a session with `kVTProfileLevel_HEVC_Main42210_AutoLevel` or a 4:4:4 pixel format, to learn whether hardware 4:2:2 or 4:4:4 is available at all. If it isn't, Workbench's answer, a tile path for text, is the practical one.
   - On LAN, consider making the sharpening pass lossless tiles of the dirty region instead of the QP-20 re-encode.
3. **Match the host display to the viewer (1:1 pixels).**
   - *Test:* the same scenes at the current scaled mapping versus a host mode matching the viewer window's backing pixels. Compare edge sharpness and bytes per second.
   - This touches the open "host display resize evaluation" item, which already has phrz's input in memory. It needs his decision, because Workbench's resize visibly rearranges host windows.
4. **Send nothing when still; no refresh traffic.**
   - *Test:* run `nettop -p <viewer pid> -L 31 -s 1 -x -J bytes_in,bytes_out` on the MacBook for Mirage and for Workbench, with the same idle desktop, typing, scroll and drag.
   - Workbench's numbers on this LAN were about 3 KB/s idle, about 1.6 Mbps average while in use, and 1 s peaks of about 5.7 Mbps. Mirage should land in the same range or explain why not. A high steady rate when still means refresh or keepalive waste.
5. **Count keyframes and recoveries per session, as Vitals does.**
   - Target zero keyframes after connect on a clean LAN, with recoveries done by LTR or tile resends.
   - *Test:* add both counters to the gate output. Inject 1% loss with the shaper and compare time-to-recover.
6. **Choose the codec by content, not by RTT or bandwidth.**
   - Astropad states it outright, and it matches the existing memory rule that latency isn't bandwidth. Network quality should move rate and FEC only, never which codec a region uses.
   - *Test:* the codec choice per frame should come out the same on LAN and on the shaper's slow profiles for the same scripted session.
7. **Frame pacing at the display rate, no reordering, small queues.**
   - *Test:* input-to-photon with the gate's camera-free method, aiming for the same order as LIQUID's under 16 ms on LAN.
   - Also measure the frame-interval distribution while dragging. Workbench held 60 fps where competitors didn't, so p95 interval should be at most 20 ms.
8. **Transport is fine as is.**
   - Mirage already runs everything over one UDP flow with parity and NACK. The only idea worth taking is to answer loss with redundancy right away rather than waiting.
   - *Test:* compare parity overhead with the stall rate at 1% loss.

## Sources
- S1 Choosing a performance codec in Workbench: https://support.astropad.com/en/articles/14204347-choosing-a-performance-codec-in-workbench
- S2 Workbench connection requirements & quality (relay, AES-256, Vitals): https://support.astropad.com/en/articles/13978237-connection-requirements-quality
- S3 Matt Ronge, "LIQUID" (2025-04-11): https://astropad.com/blog/liquid/
- S4 LIQUID technology page: https://astropad.com/liquid-technology
- S5 Workbench 1.3 coverage (2026-08-20): https://www.ithinkdiff.com/astropad-workbench-1-3-faster-streaming-privacy-curtain/
- S6 / S7 Workbench public release notes (Sparkle feed, 1.0–1.4.0): https://downloads.astropad.com/workbench/mac/sparkle.xml
- S8 Expected latency in Luna Display (2018-11-05): https://astropad.com/blog/comparing-latency-luna-display/
- S9 Early LIQUID coverage (GPU on Mac, ARM assembly on iPad): https://www.idownloadblog.com/2015/02/23/astropad-preview/
- S10 Why does my Mac's resolution look different in Workbench: https://support.astropad.com/en/articles/14092704-why-does-my-mac-s-resolution-look-different-in-workbench
- S11 TechCrunch launch article (LIQUID, "unified virtual display"): https://techcrunch.com/2026/04/08/astropads-workbench-reimagines-remote-desktop-for-ai-agents-not-it-support/ and MacRumors: https://www.macrumors.com/2026/04/08/astropad-workbench-app/

Not found: any Astropad patent, any published chroma or bit-depth figure, and any talk with codec internals.
