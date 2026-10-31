# OBS + BlueStacks settings (Ryzen 5 7600X, RTX 5060, 16 GB, Jio AirFiber ~35 Mbps up)

Menu names match OBS Studio 30.x / 31.x on Windows. If your OBS is older than 30, update it from <https://obsproject.com>. Also install a current NVIDIA driver, because the RTX 50 series needs a recent one for NVENC.

## Why change anything
Streaming at 2560x1440 asks for more bitrate than ~4000 Kbps can deliver, so the picture looks soft. It also pushes OBS toward higher bitrates. Viewers on YouTube and Twitch mostly watch at 1080p or lower. A **1080p60 (or 720p60) stream at a steady CBR bitrate** looks better and puts less load on the AirFiber upload queue.

## Settings > Output  (set **Output Mode: Advanced**)

**Streaming tab**

| Setting | Value |
|---|---|
| Audio Track | 1 |
| Video Encoder | **NVIDIA NVENC H.264** (safe default for every platform) |
| | Optional for YouTube only: **NVIDIA NVENC AV1**. YouTube accepts AV1 over Enhanced RTMP in OBS 30+. Twitch and most other platforms need H.264. |
| Rescale Output | Off (scaling is set in the Video tab) |
| Rate Control | **CBR** |
| Bitrate | YouTube: **4500-6000 Kbps** at 1080p60 (start at 4500). Twitch/others: **4000-6000 Kbps** (Twitch max 6000). With AV1, 4000-4500 Kbps is enough for 1080p60. |
| Keyframe Interval | **2 s** |
| Preset | **P5: Slow (Good Quality)**. If the GPU gets busy (encoding lag in Stats), use P4: Medium. |
| Tuning | **High Quality** |
| Multipass Mode | **Two Passes (Quarter Resolution)** |
| Profile | **high** (H.264). AV1: main |
| Look-ahead | Off (with CBR it can cause bitrate spikes) |
| Psycho Visual Tuning | On |
| GPU | 0 |
| Max B-frames | 2 |

**Audio tab:** Track 1 Audio Bitrate **160** (AAC).

**Recording tab (if you record too):** use the same NVENC encoder with **CQP / CQ 20-23** to a separate drive. This does not affect the stream.

## Settings > Video

| Setting | Value |
|---|---|
| Base (Canvas) Resolution | 2560x1440 (your monitor) |
| Output (Scaled) Resolution | **1920x1080**. Use **1280x720** if bitrate must stay at or below 4000 Kbps. |
| Downscale Filter | **Lanczos (Sharpened scaling, 36 samples)** |
| Common FPS Values | **60** |

## Settings > Advanced

| Section | Setting | Value |
|---|---|---|
| General | Process Priority | **Above Normal** |
| Video | Color Format | NV12 (default) |
| Network | **Bind to IP** | Your Ethernet IP **192.168.31.141** when using split routing (see `split-routing.ps1`). Otherwise Default. |
| Network | **Dynamically change bitrate to manage congestion** | **On**. When the uplink chokes, OBS lowers the bitrate instead of dropping frames. |
| Network | Enable network optimizations | Off by default. Turn it on only if you still see dropped frames, and compare. It changes how OBS sends data on Windows. It does not fix bufferbloat. |
| Network | Enable TCP pacing | On, if your OBS version shows this option (recent Windows builds). It spreads packets out evenly, which reduces upload bursts. |

**Stream (Settings > Stream):** use the service preset (YouTube / Twitch). Choose the closest ingest server, e.g. Twitch "Asia: Mumbai" or YouTube "Auto". OBS 30+ also offers **Ignore streaming service setting recommendations**. Leave it off so OBS warns you if a value is out of range.

**Sources:** capture BlueStacks with **Game Capture** (mode: "Capture specific window" > BlueStacks App Player). If it shows black, use **Window Capture** with Capture Method **Windows 10 (1903 and up)**.

**Check it:** open **Docks > Stats** while live. "Frames missed due to rendering lag" and "Skipped frames due to encoding lag" should be about 0%. "Dropped frames (network)" near 0% means the upload is fine.

## BlueStacks 5 (Free Fire)

Settings (gear icon):

| Section | Setting | Value |
|---|---|---|
| Performance | Performance mode | **High performance** |
| Performance | CPU allocation | **4 Cores** |
| Performance | Memory allocation | **4 GB** (OBS and Windows need the rest of the 16 GB) |
| Performance | Frame rate | **60 FPS**, with "Enable high frame rate" on. Set it equal to the OBS FPS so frame pacing stays smooth. |
| Performance | Enable VSync | Off (adds input lag) |
| Graphics | Graphics engine mode | **Performance** |
| Graphics | Graphics renderer | **DirectX** (try OpenGL/Vulkan only if you see stutter) |
| Graphics | GPU in use | **Prefer dedicated GPU (NVIDIA)** |
| Graphics | ASTC textures | Hardware decoding |
| Display | Resolution | 1920x1080, DPI 240 |

In Free Fire: Graphics **Smooth/Standard**, **High FPS on**. Higher in-game graphics settings add GPU load while NVENC is also encoding.

Windows and NVIDIA:
- Settings > System > Display > Graphics: set **HD-Player.exe** (BlueStacks) and **obs64.exe** to **High performance**. Turn on **Hardware-accelerated GPU scheduling**.
- Turn on **Game Mode** (Settings > Gaming > Game Mode).
- NVIDIA Control Panel > Manage 3D settings > Program settings > HD-Player.exe: **Low Latency Mode: On**, **Power management: Prefer maximum performance**.
- Use a wired connection and close downloaders, Steam updates, OneDrive and Windows Update downloads while streaming. All of them compete for the same upload.
