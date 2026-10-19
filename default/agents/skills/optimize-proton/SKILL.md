---
name: optimize-proton
description: >
  Optimize Omarchy's built-in Steam Proton compatibility layer (Proton-Omarchy)
  for the host CPU topology, GPU stack, and linux-omarchy kernel features (BORE,
  NTSYNC, Wayland). Use when asked to tune Proton, fix game micro-stutters, isolate
  hybrid E/LP-E cores, pin 3D V-Cache CCDs, or configure multi-GPU PRIME offload.
---

# Optimizing Proton on Omarchy Linux

Work from the machine's actual hardware facts in `/sys` and `/proc`. Never guess CPU core counts or hardcode vendor variables that do not match the installed GPUs.

## 1. Inspect Hardware & Kernel State

Check the host's live topology and kernel primitives before changing any configuration:

```bash
uname -r
cat /proc/sys/kernel/sched_bore 2>/dev/null
ls -l /dev/ntsync 2>/dev/null
for dev in /sys/bus/pci/devices/*; do
  [[ -f $dev/class ]] && [[ $(< "$dev/class") == 0x03* ]] && \
    printf "%s: vendor=%s device=%s\n" "${dev##*/}" "$(< "$dev/vendor")" "$(< "$dev/device")"
done
for c in /sys/devices/system/cpu/cpu[0-9]*; do
  printf "%s: freq=%s l3=%s\n" "${c##*/}" \
    "$(cat "$c/cpufreq/cpuinfo_max_freq" 2>/dev/null || echo 0)" \
    "$(cat "$c/cache/index3/size" 2>/dev/null || echo 0)"
done
```

## 2. Verified Proton Environment Variables

Only use environment variables that `Proton - Experimental` and Mesa/NVIDIA Vulkan loaders actually honor, and always preserve existing game launch options or compatibility workarounds (`PROTON_NO_FSYNC`, `PROTON_NO_ESYNC`, `PROTON_DISABLE_NVAPI`, `PROTON_HIDE_NVIDIA_GPU`, `PROTON_USE_WINED3D`):

- **Kernel Synchronization:** Upstream Proton automatically enables `WINEFSYNC=1` and `esync`/`ntsync` unless a game requires `nofsync`/`noesync`. Only set `PROTON_NO_FSYNC=1` or `PROTON_NO_ESYNC=1` per-game when diagnosing synchronization hangs; never strip compatibility flags passed by the user.
- **CPU Topology & Affinity:**
  - **AMD Dual-CCD 3D V-Cache (`7950X3D`, `9950X3D`):** Pin `OMAPROTON_TASKSET_CPUS` to the CCD with the `96MB` (`98304K`) L3 cache.
  - **Intel 3-Tier Hybrid (`Core Ultra`):** Exclude L3-less SoC LP-E cores (`index3/size` missing) from `OMAPROTON_TASKSET_CPUS` to prevent frame-barrier thread stalls.
  - Only set `PROTON_CPU_TOPOLOGY=<count>:<cpu_list>` per-game when a title specifically requires restricting the virtual core count exposed to Wine (avoid setting it globally so Proton's built-in `default_cpu_limit` table remains active).
- **GPU Routing:**
  - **NVIDIA (Desktop or Hybrid AC):** `__NV_PRIME_RENDER_OFFLOAD=1`, `__VK_LAYER_NV_optimus=NVIDIA_only`, `__GLX_VENDOR_LIBRARY_NAME=nvidia`, `VK_LOADER_DRIVERS_SELECT=*nvidia*`. Only add `PROTON_FORCE_NVAPI=1` or `VKD3D_CONFIG=dxr11,dxr` per-game when explicitly needed and `PROTON_DISABLE_NVAPI` / `PROTON_HIDE_NVIDIA_GPU` are not set.
  - **AMD RADV:** `RADV_PERFTEST=gpl,nggc`, `AMD_VULKAN_ICD=RADV` (plus `DRI_PRIME=1` and `MESA_VK_DEVICE_SELECT=<vendor>:<device>!` on dual-GPU systems on AC power).
  - **Intel ANV:** `ANV_GPL=true`.

## 3. Applying Per-Game vs System-Wide Overrides Safely

Never write game-specific settings into the global override file:

- **Per-Game Tuning (when a game name or Steam AppID is specified):**
  1. Resolve the numeric `SteamAppId` by checking `steamapps/appmanifest_*.acf` across the user's Steam libraries (`~/.local/share/Steam/steamapps/libraryfolders.vdf`).
  2. Write `export KEY="VALUE"` lines to `~/.config/omarchy/proton/games/<SteamAppId>.env` (permissions `0600`). `Proton-Omarchy` automatically loads `~/.config/omarchy/proton/games/${SteamAppId}.env` only when that specific game launches.
- **System-Wide Tuning (only when explicitly requested for all games):**
  - Write `export KEY="VALUE"` lines to `~/.config/omarchy/proton/overrides.env` (permissions `0600`).
