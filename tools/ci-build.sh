#!/bin/sh
set -eu

# Build one official OpenWrt package set. GitHub Actions supplies the SDK
# metadata; CI_SDK_ARCHIVE_FILE can point to a verified local copy for testing.
: "${OPENWRT_RELEASE:?}"
: "${OPENWRT_TARGET:?}"
: "${OPENWRT_SUBTARGET:?}"
: "${SDK_ARCHIVE:?}"
: "${SDK_SHA256:?}"
: "${PACKAGE_FORMAT:?}"
: "${CI_WORK_DIR:?}"
: "${CI_OUTPUT_DIR:?}"

case "$OPENWRT_RELEASE:$OPENWRT_TARGET:$OPENWRT_SUBTARGET:$PACKAGE_FORMAT" in
	24.10.8:ramips:mt76x8:ipk|25.12.5:ramips:mt76x8:apk) ;;
	*) echo 'unsupported CI package set' >&2; exit 1 ;;
esac

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
sdk_url="https://downloads.openwrt.org/releases/$OPENWRT_RELEASE/targets/$OPENWRT_TARGET/$OPENWRT_SUBTARGET/$SDK_ARCHIVE"
mkdir -p "$CI_WORK_DIR" "$CI_OUTPUT_DIR"
if [ -n "${CI_SDK_ARCHIVE_FILE:-}" ]; then
	archive="$CI_SDK_ARCHIVE_FILE"
else
	archive="$CI_WORK_DIR/$SDK_ARCHIVE"
	curl --fail --location --retry 3 --output "$archive" "$sdk_url"
fi
printf '%s  %s\n' "$SDK_SHA256" "$archive" | sha256sum -c -

tar --use-compress-program=unzstd -xf "$archive" -C "$CI_WORK_DIR"
sdk_dir="$CI_WORK_DIR/${SDK_ARCHIVE%.tar.zst}"
[ -d "$sdk_dir/package" ] || { echo 'SDK extraction failed' >&2; exit 1; }

git clone --quiet --filter=blob:none \
	https://github.com/Slava-Shchipunov/awg-openwrt.git \
	"$CI_WORK_DIR/awg-openwrt"
git -C "$CI_WORK_DIR/awg-openwrt" checkout --quiet --detach 03b62269e2edc168504f057cffaafda11b25ed92
sed -i '/^PKG_SOURCE_VERSION:=/a PKG_MIRROR_HASH:=0c27841a3b4860c7fd085cd627c5b0f9c25653afdaef1e73fd3e350fb3445dab' \
	"$CI_WORK_DIR/awg-openwrt/amneziawg-tools/Makefile"
ln -s "$repo_dir/kmod-amneziawg" "$sdk_dir/package/kmod-amneziawg"
ln -s "$CI_WORK_DIR/awg-openwrt/amneziawg-tools" "$sdk_dir/package/amneziawg-tools"
ln -s "$repo_dir" "$sdk_dir/package/tarm"
ln -s "$repo_dir/luci-app-tarm" "$sdk_dir/package/luci-app-tarm"

# A stock SDK has the toolchain but not every feed package recipe needed by
# TARM and LuCI. Install the recipes before resolving the package graph.
(
	cd "$sdk_dir"
	./scripts/feeds update base
	./scripts/feeds update packages
	./scripts/feeds update luci
	./scripts/feeds install dnsmasq nftables iproute2 util-linux uclient ca-bundle
	./scripts/feeds install -a -p luci
	printf '%s\n' \
		'CONFIG_PACKAGE_kmod-amneziawg=m' \
		'CONFIG_PACKAGE_amneziawg-tools=m' \
		'CONFIG_PACKAGE_tarm=m' \
		'CONFIG_PACKAGE_luci-app-tarm=m' >> .config
	make defconfig
	make package/kmod-amneziawg/compile package/amneziawg-tools/compile \
		package/tarm/compile package/luci-app-tarm/compile -j2
)

for package in kmod-amneziawg amneziawg-tools tarm luci-app-tarm; do
	file="$(find "$sdk_dir/bin" -type f -name "$package*.$PACKAGE_FORMAT" -print -quit)"
	[ -n "$file" ] || { echo "missing built package: $package" >&2; exit 1; }
	cp "$file" "$CI_OUTPUT_DIR/"
done

bundle="openwrt-$OPENWRT_RELEASE-$OPENWRT_TARGET-$OPENWRT_SUBTARGET"
(
	cd "$CI_OUTPUT_DIR"
	[ "$(find . -maxdepth 1 -type f -name "*.$PACKAGE_FORMAT" | wc -l)" -eq 4 ]
	sha256sum *.$PACKAGE_FORMAT > "SHA256SUMS-$bundle"
	sha256sum -c "SHA256SUMS-$bundle"
)
