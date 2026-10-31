# OpenWrt SQM (CAKE) + cake-autorate behind Jio AirFiber

Goal: keep the upload queue in **your** router, where CAKE can control it, so Free Fire packets stay fast while OBS streams. The AirFiber's own buffer then stays nearly empty.

Hardware: GL.iNet **Flint 2 (GL-MT6000)** (best, runs plain OpenWrt well) or **Beryl AX (GL-MT3000)**. Both have the CPU for CAKE at 86/35 Mbps. The GL.iNet firmware is OpenWrt-based. You can use its SSH/LuCI ("Advanced Settings"), or flash vanilla OpenWrt 23.05/24.10 for the cleanest setup.

Install status (checked 2026-10-31): the cake-autorate install steps below were checked against the official repo <https://github.com/lynxthecat/cake-autorate> (INSTALLATION.md and config.primary.sh). Check the repo again before installing, in case they have changed.

## 1. Wiring

```
Jio AirFiber LAN port --> GL.iNet WAN port
GL.iNet LAN port      --> Gaming PC
```

- The AirFiber keeps 192.168.31.0/24. The GL.iNet must use a **different LAN subnet** (GL.iNet default 192.168.8.1 is fine). Double NAT is fine for Free Fire and OBS.
- Optional: put the GL.iNet's WAN IP in the AirFiber's DMZ, if the AirFiber offers it.
- Your PC gets a new IP (e.g. 192.168.8.x). If you still use split routing, update OBS **Bind to IP**.

## 2. Install SQM

SSH in (`ssh root@192.168.8.1`):

```sh
opkg update
opkg install sqm-scripts luci-app-sqm
```

(OpenWrt 25.x uses `apk` instead of `opkg`: `apk update && apk add sqm-scripts luci-app-sqm`.)
On GL.iNet stock firmware you can instead use **Network > QoS / SQM** in the GL web UI, or its LuCI page.

Find the WAN interface name: `ip -br link`. It is often `eth1` on Beryl AX and `eth1` or `wan` on Flint 2 (vanilla OpenWrt uses `wan` on Flint 2). Use that name below.

## 3. /etc/config/sqm

Copy `sqm.example` from this folder over `/etc/config/sqm`, then change `interface`. The starting rates are about 85-90% of the measured speed:

- download 86 Mbps -> `download '75000'` (kbit/s)
- upload 35 Mbps -> `upload '28000'` (kbit/s)

Apply:

```sh
/etc/init.d/sqm enable
/etc/init.d/sqm restart
tc -s qdisc show dev wan          # should show "qdisc cake" (use your WAN name)
tc -s qdisc show dev ifb4wan      # ingress cake
```

Run the Waveform bufferbloat test. You want grade **A/A+**, with upload latency increase **under 30 ms**. If the grade is still bad, lower `upload` in steps of 2000 kbit/s.

### Why these options
- `diffserv4` sorts traffic into 4 priority classes (Bulk / Best Effort / Video / Voice). Packets marked as interactive get priority.
- `nat dual-dsthost` (ingress) and `nat dual-srchost` (egress) share bandwidth fairly **per LAN device**. The PC streaming can't starve a phone or console. `nat` makes CAKE look up the real LAN IP behind NAT.
- `ack-filter` (egress only) removes redundant TCP ACKs, which helps on an asymmetric 5G uplink.
- Overhead: the WAN port connects over Ethernet to the AirFiber. The real bottleneck is the 5G radio, and its overhead is unknown. `overhead 44` with `mpu 84` (`linklayer ethernet`) is a safe generic value. It overestimates a little, which is the safe direction.

## 4. cake-autorate (for the variable 5G uplink)

Fixed SQM rates must sit below the **worst** 5G speed, which wastes bandwidth at good times. cake-autorate measures latency continuously and moves the CAKE rate up and down between min and max.

Install (official method, from the repo's INSTALLATION.md):

```sh
opkg update && opkg install bash fping      # dependencies
wget -O /tmp/cake-autorate_setup.sh https://raw.githubusercontent.com/lynxthecat/cake-autorate/master/setup.sh
sh /tmp/cake-autorate_setup.sh
```

This installs into `/root/cake-autorate/` and creates the `cake-autorate` service. Edit `/root/cake-autorate/config.primary.sh` and set the values in `cake-autorate-config.snippet.sh` from this folder:

- `dl_if` = the ingress IFB that SQM creates, e.g. `ifb4wan` (or `ifb4eth1`). Check with `ip -br link | grep ifb`.
- `ul_if` = the WAN interface, e.g. `wan` / `eth1`.
- Rates in kbit/s, based on 86/35 Mbps:

| | min | base | max |
|---|---|---|---|
| Download | 15000 | 60000 | 86000 |
| Upload | 5000 | 20000 | 33000 |

Test in the foreground first, and watch the output while you run a speed test:

```sh
cd /root/cake-autorate
./cake-autorate.sh
```

Press Ctrl+C, then enable it as a service:

```sh
service cake-autorate enable
service cake-autorate start
tail -f /var/log/cake-autorate.primary.log
```

Notes:
- Keep SQM enabled. cake-autorate only adjusts the CAKE qdiscs that SQM creates. The rates in `/etc/config/sqm` become the starting point.
- If ping spikes still appear during uploads, lower `max_ul_shaper_rate_kbps` (e.g. 30000) or `ul_owd_delta_delay_thr_ms` (default 30.0) in the overrides section.
- If spikes happen even when the link is idle, the cause is congestion at the Jio tower. No router setting can fix that. Report it to Jio with `ping-logger.ps1` data.
- The repo's discussion thread on the OpenWrt forum ("CAKE w/ Adaptive Bandwidth") is the place for tuning help.

## 5. Optional: give the game priority with DSCP

With `diffserv4`, CAKE gives priority based on DSCP marks. Windows and BlueStacks don't mark game packets by default. The simple per-host fairness from `dual-srchost`/`dual-dsthost` is usually enough. If you want more, look at the `qosify` package (OpenWrt), which can mark traffic by port. Free Fire mostly uses UDP, and its ports vary, so this is optional.
