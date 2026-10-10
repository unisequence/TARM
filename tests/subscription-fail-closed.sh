#!/bin/sh
set -eu

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT INT TERM
AWG_ROUTE_STATE="$test_dir/state"
AWG_ROUTE_LIST_DIR="$test_dir/lists"
AWG_ROUTE_FUNCTIONS="$test_dir/functions.sh"
AWG_ROUTE_PRESET_DIR="$test_dir/presets"
mkdir -p "$AWG_ROUTE_STATE" "$AWG_ROUTE_LIST_DIR" "$AWG_ROUTE_PRESET_DIR"
: > "$AWG_ROUTE_PRESET_DIR/index"
cat > "$AWG_ROUTE_FUNCTIONS" <<'EOF'
config_load() { :; }
config_foreach() { callback="$1"; "$callback" alpha "${3:-}"; "$callback" beta "${3:-}"; }
config_get() {
	key="$3"
	case "$key" in
		enabled) value=1 ;;
		route) value=vpn ;;
		url) value="https://test.invalid/$2" ;;
		catalog) value='' ;;
		*) value="${4:-}" ;;
	esac
	eval "$1=\$value"
}
config_list_foreach() { :; }
EOF
. "$(dirname "$0")/../files/usr/share/tarm/core.sh"
awg_route_load() { AWG_ENABLED=0; }
awg_route_fetch_limited() {
	case "$2" in
		*/beta) [ "${TEST_FAIL_BETA:-0}" = 0 ] || return 1; printf 'new-beta.example\n' > "$1" ;;
		*/alpha) [ "${TEST_EMPTY_ALPHA:-0}" = 0 ] || { : > "$1"; return 0; }; printf 'new-alpha.example\n' > "$1" ;;
	esac
}
printf 'old-alpha.example\n' > "$AWG_ROUTE_LIST_DIR/alpha.txt"
printf 'old-beta.example\n' > "$AWG_ROUTE_LIST_DIR/beta.txt"
TEST_FAIL_BETA=1
if awg_route_update >/dev/null 2>&1; then echo 'partial update accepted' >&2; exit 1; fi
grep -qx 'old-alpha.example' "$AWG_ROUTE_LIST_DIR/alpha.txt"
grep -qx 'old-beta.example' "$AWG_ROUTE_LIST_DIR/beta.txt"
[ -z "$(find "$AWG_ROUTE_STATE" -name 'update.*' -print)" ]

TEST_FAIL_BETA=0 TEST_EMPTY_ALPHA=1
if awg_route_update >/dev/null 2>&1; then echo 'empty update accepted' >&2; exit 1; fi
grep -qx 'old-alpha.example' "$AWG_ROUTE_LIST_DIR/alpha.txt"

TEST_EMPTY_ALPHA=0
mv() {
	if [ "${TEST_FAIL_COMMIT:-0}" = 1 ] && [ "$1" = "$AWG_ROUTE_LIST_DIR/beta.txt.tarm-new" ]; then
		return 1
	fi
	command mv "$@"
}
TEST_FAIL_COMMIT=1
if awg_route_update >/dev/null 2>&1; then echo 'partial commit accepted' >&2; exit 1; fi
grep -qx 'old-alpha.example' "$AWG_ROUTE_LIST_DIR/alpha.txt"
grep -qx 'old-beta.example' "$AWG_ROUTE_LIST_DIR/beta.txt"
[ -z "$(find "$AWG_ROUTE_LIST_DIR" -name '*.tarm-*' -print)" ]
TEST_FAIL_COMMIT=0
awg_route_update >/dev/null
grep -qx 'new-alpha.example' "$AWG_ROUTE_LIST_DIR/alpha.txt"
grep -qx 'new-beta.example' "$AWG_ROUTE_LIST_DIR/beta.txt"

rm "$AWG_ROUTE_LIST_DIR/beta.txt"
TEST_FAIL_BETA=1
if awg_route_domains vpn > "$test_dir/domains" 2>/dev/null; then
	echo 'missing subscription cache accepted' >&2
	exit 1
fi
printf 'subscription fail-closed tests passed\n'
