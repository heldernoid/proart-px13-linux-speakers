#!/bin/sh
# ASUS ProArt PX13 (HN7306, PCI subsystem 1043:1714) internal speaker fix.
#
#   sudo ./install.sh              install / update (idempotent)
#   sudo ./install.sh --uninstall  remove everything this script installed
#   sudo ./install.sh --force      skip the hardware check
#
# Everything comes from upstream projects, nothing from third-party repos:
#  - amp firmware: linux-firmware, TI commit 2f90f4fe (2026-05-19), pinned + SHA256-checked
#  - UCM profile:  alsa-ucm-conf, TI commit 182d0122a7 (2026-07-17), backported
set -eu

FW_COMMIT=2f90f4fe5c67f51a8410907aedf911dabb7120ca
FW_URL=https://gitlab.com/kernel-firmware/linux-firmware/-/raw/$FW_COMMIT/ti/audio/tas2783
FW_DIR=/lib/firmware/updates
UCM=/usr/share/alsa/ucm2
SBIN=/usr/local/sbin
STATE_DIR=/var/lib/px13-audio
APT_HOOK=/etc/apt/apt.conf.d/99px13-audio
UNITS="px13-audio-boot.service px13-audio-resume.service"
SRC=$(cd "$(dirname "$0")" && pwd)

log() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root: sudo $0 $*"

pkg_owned() { dpkg -S "$1" >/dev/null 2>&1; }

uninstall() {
	log "disabling systemd units"
	for u in $UNITS; do
		systemctl disable --now "$u" 2>/dev/null || true
		rm -f "/etc/systemd/system/$u"
	done
	systemctl daemon-reload
	rm -f "$APT_HOOK" "$SBIN/px13-audio-check" "$SBIN/px13-audio-ucm-sync"
	if [ -r "$STATE_DIR/ucm-card-longname" ]; then
		f="$UCM/conf.d/amd-soundwire/$(cat "$STATE_DIR/ucm-card-longname").conf"
		pkg_owned "$f" || rm -f "$f"
	fi
	pkg_owned "$UCM/sof-soundwire/tas2783.conf" || rm -f "$UCM/sof-soundwire/tas2783.conf"
	log "removing firmware from $FW_DIR"
	rm -f "$FW_DIR"/1714-1-8.bin "$FW_DIR"/1714-1-B.bin \
	      "$FW_DIR"/1714-1-0x8.bin "$FW_DIR"/1714-1-0xB.bin \
	      "$FW_DIR"/ti/audio/tas2783/1714-1-0x8.bin "$FW_DIR"/ti/audio/tas2783/1714-1-0xB.bin
	rmdir -p "$FW_DIR/ti/audio/tas2783" 2>/dev/null || true
	rm -rf "$STATE_DIR"
	log "uninstalled; reboot to return to the stock state"
}

FORCE=0
case "${1:-}" in
	--uninstall) uninstall; exit 0 ;;
	--force) FORCE=1 ;;
	"") ;;
	*) die "unknown option $1" ;;
esac

# --- hardware check -------------------------------------------------------
ACP=""
for d in /sys/bus/pci/devices/*; do
	[ "$(cat "$d/vendor")" = 0x1022 ] && [ "$(cat "$d/device")" = 0x15e2 ] && ACP=$d
done
if [ $FORCE = 0 ]; then
	[ -n "$ACP" ] || die "no AMD ACP audio coprocessor (1022:15e2) found"
	[ "$(cat "$ACP/subsystem_vendor"):$(cat "$ACP/subsystem_device")" = 0x1043:0x1714 ] ||
		die "not an ASUS PX13 (ACP subsystem is $(cat "$ACP/subsystem_vendor"):$(cat "$ACP/subsystem_device"), want 0x1043:0x1714); --force to override"
	ls /sys/bus/soundwire/devices/ 2>/dev/null | grep -q 'sdw:.*:0102:0000:' ||
		die "no TI TAS2783 amps on SoundWire"
fi
modinfo snd-soc-tas2783-sdw >/dev/null 2>&1 || die "kernel lacks snd-soc-tas2783-sdw (need >= 6.17)"

# --- 1. firmware -------------------------------------------------------------
log "installing TAS2783 firmware (linux-firmware $FW_COMMIT)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
for u in 8 B; do
	f=1714-1-0x$u.bin
	if [ -r "$SRC/firmware/$f" ]; then
		cp "$SRC/firmware/$f" "$TMP/$f"
	else
		command -v curl >/dev/null || die "curl missing (or place $f in $SRC/firmware/)"
		curl -fsSL "$FW_URL/$f" -o "$TMP/$f" || die "download of $f failed"
	fi
done
(cd "$TMP" && sha256sum -c --quiet "$SRC/firmware/SHA256SUMS") || die "firmware checksum mismatch"

install -d "$FW_DIR/ti/audio/tas2783"
for u in 8 B; do
	install -m 644 "$TMP/1714-1-0x$u.bin" "$FW_DIR/ti/audio/tas2783/1714-1-0x$u.bin"
	# kernel >= 7.2 requests "1714-1-0x8.bin", older kernels "1714-1-8.bin"
	ln -sf "ti/audio/tas2783/1714-1-0x$u.bin" "$FW_DIR/1714-1-0x$u.bin"
	ln -sf "ti/audio/tas2783/1714-1-0x$u.bin" "$FW_DIR/1714-1-$u.bin"
done

# --- 2. UCM ------------------------------------------------------------------
log "installing ALSA UCM speaker profile"
if pkg_owned "$UCM/sof-soundwire/tas2783.conf"; then
	echo "    alsa-ucm-conf already ships tas2783.conf, keeping it"
else
	install -m 644 "$SRC/ucm2/sof-soundwire/tas2783.conf" "$UCM/sof-soundwire/tas2783.conf"
fi
LONGNAME=$(awk '/amd-soundwire - amd-soundwire/ {getline; gsub(/^ +| +$/, ""); print; exit}' /proc/asound/cards)
[ -n "$LONGNAME" ] || LONGNAME=ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC
install -d "$STATE_DIR"
echo "$LONGNAME" > "$STATE_DIR/ucm-card-longname"
install -m 755 "$SRC/sbin/px13-audio-ucm-sync" "$SBIN/px13-audio-ucm-sync"
"$SBIN/px13-audio-ucm-sync"
echo "    card override: $UCM/conf.d/amd-soundwire/$LONGNAME.conf"
cat > "$APT_HOOK" <<EOF
// Regenerate the PX13 UCM override after alsa-ucm-conf updates (px13-audio fix)
DPkg::Post-Invoke { "[ -x $SBIN/px13-audio-ucm-sync ] && $SBIN/px13-audio-ucm-sync || true"; };
EOF

# --- 3. boot / resume self-heal -------------------------------------------
log "installing boot/resume amp check"
install -m 755 "$SRC/sbin/px13-audio-check" "$SBIN/px13-audio-check"
for u in $UNITS; do
	install -m 644 "$SRC/systemd/$u" "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable $UNITS >/dev/null

# The driver may be loaded from the initramfs, which then needs the firmware.
if command -v update-initramfs >/dev/null &&
   lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -q tas2783; then
	log "updating initramfs"
	update-initramfs -u
fi

# --- 4. apply now (no reboot needed) --------------------------------------
log "resetting audio controller to load the firmware"
"$SBIN/px13-audio-check" || true
log "done. Pick 'Speaker' in sound settings if it is not selected automatically."
