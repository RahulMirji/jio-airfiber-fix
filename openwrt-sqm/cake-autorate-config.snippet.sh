#!/usr/bin/env bash
# shellcheck disable=SC2034
# Values to set in /root/cake-autorate/config.primary.sh for Jio AirFiber (~86/35 Mbps, variable 5G).
# Variable names match the official template at
# https://github.com/lynxthecat/cake-autorate/blob/master/config.primary.sh (checked 2026-10-31).

dl_if=ifb4wan # download interface = SQM's ingress IFB (check: ip -br link | grep ifb), e.g. ifb4eth1
ul_if=wan     # upload interface   = WAN device used in /etc/config/sqm, e.g. eth1

adjust_dl_shaper_rate=1
adjust_ul_shaper_rate=1

min_dl_shaper_rate_kbps=15000   # floor during heavy tower congestion
base_dl_shaper_rate_kbps=60000  # steady-state starting point
max_dl_shaper_rate_kbps=86000   # best measured download

min_ul_shaper_rate_kbps=5000    # floor; keeps game + ~4 Mbps stream usable on a bad uplink
base_ul_shaper_rate_kbps=20000  # steady-state starting point
max_ul_shaper_rate_kbps=33000   # just under the best measured 35 Mbps upload

connection_active_thr_kbps=2000

# *** OVERRIDES *** (optional, see defaults.sh in the repo)
# ul_owd_delta_delay_thr_ms=30.0   # lower (e.g. 20.0) for a more aggressive upload cut on latency rise
# dl_owd_delta_delay_thr_ms=30.0
# startup_wait_s=30.0              # wait for the WAN to come up after router reboot
