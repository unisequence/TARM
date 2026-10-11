#!/bin/sh
set -eu

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT INT TERM

AWG_ROUTE_STATE="$test_dir/state"
AWG_ROUTE_TUNNEL="$test_dir/tunnel.conf"
export AWG_ROUTE_STATE AWG_ROUTE_TUNNEL
. "$(dirname "$0")/../files/usr/share/tarm/core.sh"

printf '[Interface]\r\nPrivateKey = testkey\r\nAddress = 10.20.0.2/32, fd00::2/128\r\nMTU = 1280\r\nJc = 5\r\n[Peer]\r\nPublicKey = peerkey\r\nAllowedIPs = 0.0.0.0/0, ::/0\r\nEndpoint = vpn.example.org:51820\r\n' > "$test_dir/input.conf"
awg_route_import "$test_dir/input.conf" >/dev/null
awg_route_tunnel_prepare
[ "$AWG_ADDRESSES" = ' 10.20.0.2/32 fd00::2/128' ]
[ "$AWG_MTU" = 1280 ]
grep -q 'Jc = 5' "$AWG_ROUTE_STATE/tunnel.setconf"
! grep -q 'Address' "$AWG_ROUTE_STATE/tunnel.setconf"
[ "$(stat -c %a "$AWG_ROUTE_TUNNEL")" = 600 ]
cp "$AWG_ROUTE_TUNNEL" "$test_dir/known-good.conf"
printf '[Interface]\nPrivateKey = testkey\nAddress = 999.2.3.4/32\n[Peer]\nPublicKey = peerkey\n' > "$test_dir/bad.conf"
if awg_route_import "$test_dir/bad.conf" >/dev/null 2>&1; then
	echo 'malformed tunnel import accepted' >&2
	exit 1
fi
cmp "$AWG_ROUTE_TUNNEL" "$test_dir/known-good.conf"

printf '%s\n' 'Example.Org' '.sub.example.org' 'bad domain' > "$test_dir/domains"
if awg_route_normalize < "$test_dir/domains" > "$test_dir/normalized" 2>/dev/null; then
	echo 'invalid domain accepted' >&2
	exit 1
fi
printf '%s\n' 'Example.Org' '.sub.example.org' > "$test_dir/domains"
awg_route_normalize < "$test_dir/domains" > "$test_dir/normalized"
grep -qx 'example.org' "$test_dir/normalized"
grep -qx 'sub.example.org' "$test_dir/normalized"

printf '%s\n' 'Example.Org' '203.0.113.7' '198.51.100.0/24' '2001:DB8::1' '2001:db8:abcd::/48' > "$test_dir/mixed"
awg_route_classify "$test_dir/classified" < "$test_dir/mixed"
grep -qx 'example.org' "$test_dir/classified.domains"
grep -qx '203.0.113.7' "$test_dir/classified.ip4"
grep -qx '198.51.100.0/24' "$test_dir/classified.ip4"
grep -qx '2001:db8::1' "$test_dir/classified.ip6"
grep -qx '2001:db8:abcd::/48' "$test_dir/classified.ip6"
for bad_entry in '999.2.3.4' '192.0.2.0/33' '2001:db8::/129' '2001:::1' 'not a domain'; do
	if printf '%s\n' "$bad_entry" | awg_route_classify "$test_dir/invalid" 2>/dev/null; then
		echo "invalid entry accepted: $bad_entry" >&2
		exit 1
	fi
done

config_get() {
	case "$3" in
		enabled) [ "$2" = disabled ] && eval "$1=0" || eval "$1=${4:-}" ;;
		route) [ "$2" = direct ] && eval "$1=direct" || eval "$1=vpn" ;;
		url|catalog) eval "$1=''" ;;
	esac
}
config_list_foreach() {
	"$3" 'example.org'
	"$3" 'video.example.net'
}
[ "$(awg_route_list_domains streaming vpn)" = "$(printf 'example.org\nvideo.example.net')" ]
[ "$(awg_route_list_domains missing vpn)" = "$(printf 'example.org\nvideo.example.net')" ]
[ -z "$(awg_route_list_domains streaming direct)" ]
[ -z "$(awg_route_list_domains disabled vpn)" ]

AWG_ROUTE_IMPORT="$test_dir/import.txt"
AWG_ROUTE_MANUAL_DIR="$test_dir/manual"
awg_route_load() { AWG_ENABLED=0; }
uci() {
	[ "$1" != -q ] || shift
	[ "$1" != get ] || printf 'list\n'
}
printf 'https://Video.Example.org/watch\n.example.net\n# comment\n' > "$AWG_ROUTE_IMPORT"
awg_route_import_list video replace >/dev/null
grep -qx 'video.example.org' "$AWG_ROUTE_MANUAL_DIR/video.txt"
grep -qx 'example.net' "$AWG_ROUTE_MANUAL_DIR/video.txt"
printf 'video.example.org\nnew.example.org\n203.0.113.7\n2001:db8::/32\n' > "$AWG_ROUTE_IMPORT"
awg_route_import_list video append >/dev/null
[ "$(wc -l < "$AWG_ROUTE_MANUAL_DIR/video.txt")" -eq 5 ]
grep -qx '203.0.113.7' "$AWG_ROUTE_MANUAL_DIR/video.txt"
grep -qx '2001:db8::/32' "$AWG_ROUTE_MANUAL_DIR/video.txt"
printf 'bad domain with spaces\n' > "$AWG_ROUTE_IMPORT"
if awg_route_import_list video replace >/dev/null 2>&1; then
	echo 'invalid bulk import accepted' >&2
	exit 1
fi
[ "$(wc -l < "$AWG_ROUTE_MANUAL_DIR/video.txt")" -eq 5 ]

mkdir -p "$test_dir/bin"
printf 'domain:telegram.org\ninclude:extra\nfull:exact.example.org\n' > "$test_dir/telegram"
printf 't.me\ninclude:telegram\n' > "$test_dir/extra"
printf 'domain:whatsapp.com\n' > "$test_dir/whatsapp"
cat > "$test_dir/bin/uclient-fetch" <<'EOF'
#!/bin/sh
case "$4" in
	*/telegram) cp "$AWG_TEST_DIR/telegram" "$3" ;;
	*/extra) cp "$AWG_TEST_DIR/extra" "$3" ;;
	*/whatsapp) cp "$AWG_TEST_DIR/whatsapp" "$3" ;;
	*/too-large) cp "$AWG_TEST_DIR/too-large" "$3" ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/uclient-fetch"
AWG_TEST_DIR="$test_dir"
AWG_ROUTE_TELEGRAM_CIDR="$test_dir/telegram-cidr.txt"
printf '149.154.160.0/20\n2001:67c:4e8::/48\n' > "$AWG_ROUTE_TELEGRAM_CIDR"
AWG_ROUTE_META_CIDR="$test_dir/meta-cidr.txt"
printf '31.13.64.0/18\n2a03:2880::/32\n' > "$AWG_ROUTE_META_CIDR"
PATH="$test_dir/bin:$PATH"
export AWG_TEST_DIR AWG_ROUTE_TELEGRAM_CIDR AWG_ROUTE_META_CIDR PATH
head -c 4096 /dev/zero > "$test_dir/too-large"
if awg_route_fetch_limited "$test_dir/limited" 'https://example.org/too-large' 1024 2>/dev/null; then
	echo 'oversized download accepted' >&2
	exit 1
fi
[ "$(wc -c < "$test_dir/limited")" -le 2048 ]
awg_route_fetch_limited "$test_dir/limited" 'https://example.org/telegram' 1024
awg_route_catalog_fetch telegram "$test_dir/catalog.txt"
grep -qx 'telegram.org' "$test_dir/catalog.txt"
grep -qx 't.me' "$test_dir/catalog.txt"
grep -qx '149.154.160.0/20' "$test_dir/catalog.txt"
grep -qx '2001:67c:4e8::/48' "$test_dir/catalog.txt"
! grep -q 'exact.example.org' "$test_dir/catalog.txt"
awg_route_catalog_fetch whatsapp "$test_dir/whatsapp-catalog.txt"
grep -qx 'whatsapp.com' "$test_dir/whatsapp-catalog.txt"
grep -qx '31.13.64.0/18' "$test_dir/whatsapp-catalog.txt"
grep -qx '2a03:2880::/32' "$test_dir/whatsapp-catalog.txt"

AWG_ROUTE_PRESET_DIR="$test_dir/presets"
mkdir -p "$AWG_ROUTE_PRESET_DIR"
printf 'meta\ntelegram\n' > "$AWG_ROUTE_PRESET_DIR/index"
printf 'whatsapp.com\n31.13.64.0/18\n' > "$AWG_ROUTE_PRESET_DIR/meta.txt"
printf 'telegram.org\n' > "$AWG_ROUTE_PRESET_DIR/telegram.txt"
uci() {
	[ "$1" != -q ] || shift
	[ "$1" = get ] || return 1
	[ "$2" = tarm.main.preset_meta ] && printf '1\n'
}
awg_route_preset_domains > "$test_dir/preset-output"
grep -qx 'whatsapp.com' "$test_dir/preset-output"
grep -qx '31.13.64.0/18' "$test_dir/preset-output"
! grep -q 'telegram.org' "$test_dir/preset-output"
rm "$AWG_ROUTE_PRESET_DIR/meta.txt"
if awg_route_preset_domains >/dev/null 2>&1; then
	echo 'missing enabled preset accepted' >&2
	exit 1
fi

# Updating an existing table must keep the DNS-populated sets and commit all
# static set and chain changes in a single nftables transaction.
AWG_LAN=br-lan
AWG_IFACE=awg0
AWG_MARK=0x700000
AWG_ROUTE_STATE="$test_dir/nft-state"
mkdir -p "$AWG_ROUTE_STATE"
printf '31.13.64.0/18\n' > "$AWG_ROUTE_STATE/vpn.ip4"
: > "$AWG_ROUTE_STATE/vpn.ip6"
: > "$AWG_ROUTE_STATE/direct.ip4"
: > "$AWG_ROUTE_STATE/direct.ip6"
nft() {
	case "$1" in
		list) return 0 ;;
		-c) return 0 ;;
		-f) cp "$2" "$test_dir/nft-committed" ;;
	esac
}
awg_route_write_nft
cmp "$AWG_ROUTE_STATE/table.nft" "$test_dir/nft-committed"
grep -q '^flush set inet awg_route vpn4_static$' "$test_dir/nft-committed"
grep -q '^flush chain inet awg_route mark_lan$' "$test_dir/nft-committed"
grep -q 'ct mark set ct mark & 0xff8fffff return' "$test_dir/nft-committed"
! grep -q 'flush set inet awg_route vpn4$' "$test_dir/nft-committed"
! grep -q 'delete table' "$test_dir/nft-committed"

# Malformed interface addresses must be rejected before the old addresses are
# removed from a live tunnel.
printf '[Interface]\nPrivateKey = testkey\nAddress = 999.2.3.4/32\n[Peer]\nPublicKey = peerkey\n' > "$AWG_ROUTE_TUNNEL"
if awg_route_tunnel_prepare 2>/dev/null; then
	echo 'invalid tunnel address accepted' >&2
	exit 1
fi

# Stop must identify TARM's own rules and routes, never delete by priority or
# flush the whole routing table when another service uses the same numbers.
AWG_TABLE=700
AWG_MARK=0x700000
AWG_IFACE=awg0
ip() { printf '%s\n' "$*" >> "$test_dir/ip-cleanup"; }
for dns in '' 1.1.1.1 2001:db8::1; do
	AWG_DNS_SERVER="$dns"
	: > "$test_dir/ip-cleanup"
	awg_route_cleanup_policy
	grep -qx -- '-4 rule del priority 17000 fwmark 0x700000/0x700000 table 700' "$test_dir/ip-cleanup"
	grep -qx -- '-6 rule del priority 17000 fwmark 0x700000/0x700000 table 700' "$test_dir/ip-cleanup"
	grep -qx -- '-4 route del default dev awg0 table 700 metric 10' "$test_dir/ip-cleanup"
	grep -qx -- '-6 route del blackhole default table 700 metric 100' "$test_dir/ip-cleanup"
	! grep -q 'route flush\|rule del priority 17000$' "$test_dir/ip-cleanup"
	case "$dns" in
		'') ! grep -q 'priority 16999' "$test_dir/ip-cleanup" ;;
		1.1.1.1)
			grep -qx -- '-4 rule del priority 16999 iif lo to 1.1.1.1 table 700' "$test_dir/ip-cleanup"
			grep -qx -- '-4 rule del priority 16999 to 1.1.1.1 table 700' "$test_dir/ip-cleanup"
			! grep -q -- '-6 rule del priority 16999' "$test_dir/ip-cleanup" ;;
		*)
			grep -qx -- '-6 rule del priority 16999 iif lo to 2001:db8::1 table 700' "$test_dir/ip-cleanup"
			grep -qx -- '-6 rule del priority 16999 to 2001:db8::1 table 700' "$test_dir/ip-cleanup"
			! grep -q -- '-4 rule del priority 16999' "$test_dir/ip-cleanup" ;;
	esac
done

# A VPN DNS route is needed by local dnsmasq queries, but must not catch
# unmarked packets sent directly to the same resolver by LAN clients.
ip() {
	case "$*" in
		'-4 rule show'|'-6 rule show') printf '17000: from all fwmark 0x700000/0x700000 lookup 700\n' ;;
		*) printf '%s\n' "$*" >> "$test_dir/ip-routes" ;;
	esac
}
AWG_ROUTE_FORCE_DOWN=1
for dns in 1.1.1.1 2001:db8::1; do
	AWG_DNS_SERVER="$dns"
	: > "$test_dir/ip-routes"
	awg_route_routes
	case "$dns" in
		1.1.1.1) grep -qx -- '-4 rule add priority 16999 iif lo to 1.1.1.1 table 700' "$test_dir/ip-routes" ;;
		*) grep -qx -- '-6 rule add priority 16999 iif lo to 2001:db8::1 table 700' "$test_dir/ip-routes" ;;
	esac
done

echo 'core tests passed'
