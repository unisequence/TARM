#!/bin/sh
set -eu

: "${RELEASE_TAG:?}"
: "${CI_ARTIFACT_DIR:?}"
: "${CI_RELEASE_DIR:?}"
repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
version="$(sed -n 's/^PKG_VERSION:=//p' "$repo_dir/Makefile")"
[ "$RELEASE_TAG" = "v$version" ] || { echo 'tag and package version differ' >&2; exit 1; }
grep -Fqx "tag='$RELEASE_TAG'" "$repo_dir/install.sh" || {
	echo 'installer and release tag differ' >&2; exit 1;
}
grep -Fqx "PKG_VERSION:=$version" "$repo_dir/luci-app-tarm/Makefile" || {
	echo 'LuCI and TARM versions differ' >&2; exit 1;
}

mkdir -p "$CI_RELEASE_DIR"
for bundle in \
	openwrt-24.10.8-ramips-mt76x8 \
	openwrt-25.12.5-ramips-mt76x8 \
	openwrt-24.10.8-ramips-mt7621 \
	openwrt-25.12.5-ramips-mt7621; do
	source_dir="$CI_ARTIFACT_DIR/$bundle"
	[ -d "$source_dir" ] || { echo "missing artifact: $bundle" >&2; exit 1; }
	(cd "$source_dir" && sha256sum -c "SHA256SUMS-$bundle")
	(cd "$source_dir" && tar -czf "$CI_RELEASE_DIR/$bundle.tar.gz" -- .)
done

cp "$repo_dir/install.sh" "$CI_RELEASE_DIR/install.sh"
[ "$(find "$CI_RELEASE_DIR" -maxdepth 1 -type f | wc -l)" -eq 5 ] || {
	echo 'unexpected release asset count' >&2; exit 1;
}
grep -Fqx 'archive="$bundle.tar.gz"' "$repo_dir/install.sh" || {
	echo 'installer does not select bundle archives' >&2; exit 1;
}
