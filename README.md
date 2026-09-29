# ASUS ProArt PX13 (HN7306) internal speakers on Linux

Fixes silent internal speakers ("Dummy Output") on the ASUS ProArt PX13
(HN7306, AMD Strix Halo, PCI subsystem `1043:1714`), using only upstream
sources: no PPA, no third-party blobs, no out-of-tree kernel module.

Tested: Ubuntu 26.04.1, kernel 7.0.0-34-generic, BIOS HN7306EAC.310.

## Why the speakers are silent

The speakers are driven by two TI **TAS2783** smart amps on AMD's SoundWire
bus. The kernel driver (`snd-soc-tas2783-sdw`) is already in mainline and
binds fine. Three things are missing:

| Layer | Problem | Upstream fix | Ubuntu 26.04 status |
|---|---|---|---|
| Firmware | Each amp needs a per-model DSP tuning file, `1714-1-8.bin` / `1714-1-B.bin`. Without it: `error playback without fw download`. | linux-firmware `2f90f4fe` (TI, 2026-05-19) adds `ti/audio/tas2783/1714-1-0x{8,B}.bin`, labelled `HN7306_LS_alpha10_stereo_tuning_v1_251014` | not yet (package is 20260319) |
| Filename | Kernel ≤ 7.1 asks for `1714-1-8.bin`; the files upstream are named `…-0x8.bin`. | kernel 7.2 asks for `-0x8` first, then falls back to the old name | 7.0 kernel |
| UCM | No `tas2783.conf`, and the AMD machine driver doesn't advertise `spk:tas2783`, so PipeWire never gets a Speaker sink. | alsa-ucm-conf `182d0122a7` (TI, 2026-07-17) | not yet |
| Resume | Amps lose firmware after s2idle resume. | open: [kernel bug 221798](https://bugzilla.kernel.org/show_bug.cgi?id=221798) | – |

## What `install.sh` does

1. **Firmware.** Downloads the two TI files from the pinned linux-firmware
   commit and verifies them against `firmware/SHA256SUMS`. It installs them to
   `/lib/firmware/updates/ti/audio/tas2783/`, with symlinks under both the
   old (≤ 7.1) and new (≥ 7.2) names. For offline installs, put the `.bin`
   files in `firmware/` first. License: TI "Redistributable", see
   `LICENCE.ti-tspa` in linux-firmware.
2. **UCM.** Installs the upstream `tas2783.conf` and generates a card-specific
   copy of the stock `amd-soundwire.conf` that sets `SpeakerCodec1 "tas2783"`.
   An apt hook regenerates that copy whenever `alsa-ucm-conf` updates. It
   never overwrites package-owned files.
3. **Self-heal.** `px13-audio-check` runs at boot and after resume. If the
   amps don't accept a stream, it resets the ACP controller (PCI unbind/bind,
   which re-downloads firmware) and restarts WirePlumber for logged-in users.
4. Applies the fix immediately; no reboot needed.

## Usage

```sh
git clone <this repo> px13-audio && cd px13-audio
sudo ./install.sh
# then pick "Speaker" in sound settings if it isn't already the default

sudo ./install.sh --uninstall   # remove everything
```

The installer refuses to run on anything other than subsystem `1043:1714`
with TAS2783 amps present. `--force` skips that check, but other models need
their own tuning files: **never use another model's amp firmware**, because
wrong speaker-protection parameters can damage speakers.

## Checking it works

```sh
sudo /usr/local/sbin/px13-audio-check      # "speaker amps OK"
wpctl status                               # "Audio Coprocessor Speaker"
pw-play /usr/share/sounds/alsa/Front_Left.wav
journalctl -b -u px13-audio-boot -u px13-audio-resume
```

Harmless noise: `SDW1-PIN4-CAPTURE-SmartAmp ... Program transport params
failed: -22`. That's the amps' I/V-sense capture stream, which WirePlumber
probes and the 7.0 kernel rejects. Playback is unaffected.

## Troubleshooting: still "Dummy Output"

If `sudo /usr/local/sbin/px13-audio-check` says `speaker amps OK` but sound
settings still show only "Dummy Output", WirePlumber lost track of the card
when it disappeared and came back during a controller reset. Its log shows
`spa.alsa: ... No such device`. Restart the user audio services, no sudo
needed:

```sh
systemctl --user restart wireplumber pipewire pipewire-pulse
```

`px13-audio-check` does this automatically after a reset, but you may need it
by hand after unusual sequences, such as several resets in quick succession.

## When can this be removed?

Once your distro ships linux-firmware ≥ 20260519, alsa-ucm-conf with
`182d0122a7`, and a kernel where bug 221798 is fixed, run
`sudo ./install.sh --uninstall`.
