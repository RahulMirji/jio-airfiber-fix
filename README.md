# Jio AirFiber lag fix kit (Free Fire + OBS streaming)

Your setup: Ryzen 5 7600X, RTX 5060, 16 GB, Ethernet to Jio AirFiber (gateway `192.168.31.1`, PC `192.168.31.141`, about 86/35 Mbps).

**What's wrong:** ping jumps to 700-1100 ms whenever you upload (OBS stream). That is **bufferbloat**: the AirFiber unit queues too much upload data, and your game packets wait behind the stream. The phone hotspot feels smooth because the game no longer shares that queue with the stream.

Files in this kit:

| File | Purpose |
|---|---|
| `ping-logger.ps1` | Logs pings to the router, the first Jio hop and 1.1.1.1 to CSV, then prints min/avg/p95/max/loss |
| `split-routing.ps1` | Sends the game over the phone hotspot and keeps OBS on AirFiber (`-Revert` undoes it) |
| `obs-settings.md` | OBS + BlueStacks settings for this PC |
| `openwrt-sqm/` | Long-term fix: an OpenWrt router with CAKE SQM and cake-autorate |

---

## Step 0: Allow the scripts to run (once)

Open **PowerShell as Administrator** in the folder with these files, then run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Unblock-File .\*.ps1
```

This only applies to the current window.

---

## Step 1: Quick tests (10 minutes, on Ethernet, hotspot unplugged)

1. **Bufferbloat test:** go to <https://www.waveform.com/tools/bufferbloat>. Note the grade and the "Active upload" latency. A grade of C or worse with +300 ms on upload confirms the problem.
2. **Cloudflare test:** go to <https://speed.cloudflare.com>. Note "Latency during upload" next to the idle latency.
3. **Find the first Jio hop:**
   ```cmd
   tracert -d -h 6 1.1.1.1
   ```
   Hop 1 is `192.168.31.1` (your AirFiber). On this connection the next hops show as `192.0.0.1`. That address is the AirFiber's internal 5G stack, and **it doesn't reply to normal ping**. So there's no Jio hop worth pinging. Compare the router against 1.1.1.1 instead.
4. **Concurrent pings while uploading.** Open two Command Prompt windows and run one command in each:
   ```cmd
   ping -t 192.168.31.1
   ping -t 1.1.1.1
   ```
   Then start the Waveform test again, or go live in OBS. Or let the logger run both at once (press Enter when it asks for a Jio hop):
   ```powershell
   .\ping-logger.ps1 -Minutes 5
   ```

**How to read it:**
- `192.168.31.1` stays low (1-3 ms) but 1.1.1.1 jumps to hundreds of ms: the queue is in the AirFiber's 5G link. This is the usual result.
- `192.168.31.1` itself spikes: check the Ethernet cable, port and NIC driver first.

**Already measured (31 Oct 2026, from a Mac on the same Jio network):**

| Condition | 1.1.1.1 avg / p95 / max | Loss |
|---|---|---|
| Idle | 28-53 / 80-165 / 263-1309 ms | 0% |
| Upload + download load | 112 / 467 / 1499 ms | 6% |
| Upload only | 53 / 186 / 562 ms | 0.8% |
| Download only | 25 / 64 / 212 ms | 4.4% |

The router stayed under 30 ms the whole time. The spikes start at the first hop past the 5G radio. Upload load makes them much worse (responsiveness was "Low", 134 RPM). Spikes also happen with no load, which points to tower/cell congestion. No router setting can remove those.

Run the logger at different times (morning, evening peak, late night) to see whether it is tower congestion. Keep the CSVs for Jio.

---

## Step 2: Fix 1, split routing (free, works today)

The game goes over the phone hotspot. OBS stays on AirFiber.

1. Connect the phone by **USB tethering** (more stable) or the hotspot over Wi-Fi. Keep the Ethernet cable plugged in.
2. In admin PowerShell:
   ```powershell
   .\split-routing.ps1
   ```
   Pick the hotspot adapter, then the Ethernet adapter. The script makes the hotspot the default route (metric 5) and Ethernet the backup (metric 50).
3. In OBS, open **Settings > Advanced > Network > Bind to IP** and choose **`192.168.31.141`** (your Ethernet IP). Click Apply and restart OBS. Now the stream uses AirFiber while BlueStacks uses the hotspot.
4. Check it: go live, then check the OBS stats dock (**Docks > Stats**). Dropped frames should be 0%, and phone data use should stay small. Free Fire uses roughly 30-80 MB per hour.
5. To undo: `.\split-routing.ps1 -Revert`

Tip: reserve `192.168.31.141` for the PC in the AirFiber router's DHCP settings, or set a static IP. Otherwise the OBS binding breaks if the IP changes.

---

## Step 3: Fix 2, OBS settings

Follow `obs-settings.md`. The main changes are 1080p60 (or 720p60) output instead of 1440p, NVENC, CBR 4500-6000 Kbps, and dynamic bitrate on. A lower, steadier upload puts less load on the AirFiber queue.

---

## Step 4: Fix 3, SQM router (best long-term fix, about Rs 3,000-10,000)

Put an OpenWrt router (GL.iNet Beryl AX or Flint 2) between the AirFiber and the PC. Run CAKE SQM with cake-autorate on it. This keeps the queue in your own router, where gaming packets get priority, so you can game and stream on AirFiber alone. See `openwrt-sqm/README.md`.

Notes for your router (Jio indoor unit **JIDU6601**, firmware JUICEJFV-1.5.5):
- Bridge mode probably isn't available, so use double NAT. Put the GL.iNet's WAN IP in the Jio DMZ if the menu has one.
- Cable it from a Jio **LAN** port to the GL.iNet **WAN** port. Leave the Jio WAN port (the one going to the outdoor unit) alone.
- **Turn off the Jio Wi-Fi** and connect every device to the GL.iNet. Any device left on the Jio Wi-Fi bypasses SQM and can still fill the upload queue.
- Cap the upload at about 28-31 Mbps (`sqm.example` starts at 28 Mbps). SQM fixes the upload bufferbloat but not the idle spikes from the tower.
- Jio hands out only a /64 for IPv6. If IPv6 doesn't work behind the GL.iNet, set IPv6 to relay mode or disable it.

---

## Step 5: What to tell Jio support

Use the MyJio app (AirFiber > Help) or call customer care. Ask for a **technical complaint**, not a speed complaint:

> "My AirFiber has latency spikes up to 1.3 seconds even when idle, and up to 1.5 seconds with 6% packet loss under upload load. Ping to my AirFiber router (192.168.31.1) stays at 1-3 ms. Traceroute shows the spikes start at the first hop past the 5G radio, so the problem is the 5G link or the tower, not my LAN. Waveform bufferbloat grade: __. Please check the outdoor unit's signal (RSRP/SINR), the band and cell load on my tower, and the unit's firmware. Please also confirm whether the unit can be realigned or moved to a less congested cell."

Before you call, check the signal yourself. Log in at `https://192.168.31.1` (or open the JioHome app) and look for RSRP and SINR on the dashboard or the network/ODU status page. As a rough guide, SINR above 13 dB is good and below 5 dB is poor. RSRP above -90 dBm is good and below -105 dBm is weak. Weak values make a strong case for an ODU realignment.

Attach the CSVs and summaries from `ping-logger.ps1` (best from peak and off-peak hours) and screenshots of the Waveform and Cloudflare results. Ask for the complaint/SR number.
