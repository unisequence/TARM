#!/bin/sh
# Install the TARM package set matching an official OpenWrt image.
set -eu
umask 077

tag='v0.8.0'
base_url="${TARM_RELEASE_BASE_URL:-https://github.com/unisequence/TARM/releases/download/$tag}"
release_file="${TARM_RELEASE_FILE:-/etc/openwrt_release}"

fail() { echo "tarm installer: $*" >&2; exit 1; }
[ -r "$release_file" ] || fail 'OpenWrt release information is missing'
. "$release_file"
case "${DISTRIB_TARGET:-}" in
	ramips/mt76x8|ramips/mt7621) ;;
	*) fail 'only ramips/mt76x8 and ramips/mt7621 are supported by this release' ;;
esac
[ "${DISTRIB_ARCH:-}" = 'mipsel_24kc' ] || fail 'unexpected package architecture'

bundle="openwrt-${DISTRIB_RELEASE:-unknown}-${DISTRIB_TARGET%%/*}-${DISTRIB_TARGET##*/}"
case "${DISTRIB_RELEASE:-}:${DISTRIB_TARGET:-}" in
	24.10.8:ramips/mt76x8)
		manager=opkg
		kernel_expected='6.6.144~4ca73159125334b180ac4bba6dc45839-r1'
		kernel_running='6.6.144' ;;
	24.10.8:ramips/mt7621)
		manager=opkg
		kernel_expected='6.6.144~f31f6f85a36836e510d64a18a9a5f1bf-r1'
		kernel_running='6.6.144' ;;
	25.12.5:ramips/mt76x8)
		manager=apk
		kernel_expected='6.12.94~2fe195f1cc4f533c70c3c6ea555ac460-r1'
		kernel_running='6.12.94' ;;
	25.12.5:ramips/mt7621)
		manager=apk
		kernel_expected='6.12.94~35fb64ea09ee15c2f267bd5436b7f178-r1'
		kernel_running='6.12.94' ;;
	*) fail 'this OpenWrt version and target have no tested package set' ;;
esac

if [ "$manager" = opkg ]; then
	set -- \
		'kmod-amneziawg_6.6.144.3.1.20260812-r3_mipsel_24kc.ipk' \
		'amneziawg-tools_3.1.20260812-r1_mipsel_24kc.ipk' \
		'tarm_0.8.0-r1_all.ipk' \
		'luci-app-tarm_0.8.0-r1_all.ipk'
else
	set -- \
		'kmod-amneziawg-6.12.94.3.1.20260812-r3.apk' \
		'amneziawg-tools-3.1.20260812-r1.apk' \
		'tarm-0.8.0-r1.apk' \
		'luci-app-tarm-0.8.0-r1.apk'
fi

command -v "$manager" >/dev/null 2>&1 || fail "$manager is missing"
command -v uclient-fetch >/dev/null 2>&1 || fail 'uclient-fetch is missing'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is missing'
[ "$(uname -r)" = "$kernel_running" ] || fail 'running kernel version does not match this package set'

if [ "$manager" = opkg ]; then
	kernel_installed="$(opkg status kernel | sed -n 's/^Version: //p' | head -n 1)"
else
	kernel_installed="$(apk info -v kernel | sed -n 's/^kernel-//p' | head -n 1)"
fi
[ "$kernel_installed" = "$kernel_expected" ] || fail "kernel ABI mismatch: expected $kernel_expected, found ${kernel_installed:-none}"

work="$(mktemp -d /tmp/tarm-install.XXXXXX)" || fail 'could not create temporary directory'
cleanup() { [ -z "${work:-}" ] || rm -rf "$work"; }
trap cleanup 0
trap 'exit 1' 1 2 3 15

fetch() {
	local name="$1" attempt
	for attempt in 1 2 3; do
		if uclient-fetch --quiet --timeout=30 -O "$work/$name" "$base_url/$name"; then return 0; fi
		sleep 2
	done
	fail "download failed: $name"
}

archive="$bundle.tar.gz"
echo "Downloading $bundle from $base_url"
fetch "$archive"
tar -xzf "$work/$archive" -C "$work" || fail 'could not unpack package bundle'
manifest="SHA256SUMS-$bundle"
(cd "$work" && sha256sum -c "$manifest") || fail 'package checksum mismatch'
for package in "$@"; do
	[ -f "$work/$package" ] || fail "missing package: $package"
done

if [ "$manager" = opkg ]; then
	opkg update || fail 'opkg update failed; no packages were changed'
	if opkg status dnsmasq | grep -q '^Status: install'; then
		echo 'Replacing dnsmasq with dnsmasq-full'
		opkg remove dnsmasq || fail 'could not remove the base dnsmasq package'
	fi
	opkg install "$work/$1" "$work/$2" "$work/$3" "$work/$4" || {
		if ! opkg status dnsmasq-full | grep -q '^Status: install'; then
			opkg install dnsmasq >/dev/null 2>&1 || true
		fi
		fail 'package installation failed'
	}
else
	apk update || fail 'apk update failed; no packages were changed'
	apk add --allow-untrusted --no-scripts --no-commit-hooks \
		"$work/$1" "$work/$2" "$work/$3" "$work/$4" || fail 'package installation failed'
	[ ! -x /etc/uci-defaults/95-tarm-cron ] || /etc/uci-defaults/95-tarm-cron
fi

/etc/init.d/tarm enable || fail 'could not enable TARM startup'
/etc/init.d/rpcd restart || fail 'could not refresh LuCI permissions'
/etc/init.d/uhttpd reload >/dev/null 2>&1 || true
if [ "$(uci -q get tarm.main.enabled 2>/dev/null || true)" = 1 ]; then
	/usr/bin/tarm apply || fail 'packages installed, but TARM apply failed'
fi
echo 'TARM installed. Open Services → TARM in LuCI.'
