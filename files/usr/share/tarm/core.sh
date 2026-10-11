#!/bin/sh

AWG_ROUTE_CONFIG="${AWG_ROUTE_CONFIG:-tarm}"
AWG_ROUTE_STATE="${AWG_ROUTE_STATE:-/var/run/tarm}"
AWG_ROUTE_DNS_CONF="${AWG_ROUTE_DNS_CONF:-}"
AWG_ROUTE_FW_INCLUDE="${AWG_ROUTE_FW_INCLUDE:-/usr/share/nftables.d/chain-pre/forward/tarm.nft}"
AWG_ROUTE_TUNNEL="${AWG_ROUTE_TUNNEL:-/etc/tarm/tunnel.conf}"
AWG_ROUTE_IMPORT="${AWG_ROUTE_IMPORT:-/etc/tarm/import.txt}"
AWG_ROUTE_MANUAL_DIR="${AWG_ROUTE_MANUAL_DIR:-/etc/tarm/manual}"
AWG_ROUTE_LIST_DIR="${AWG_ROUTE_LIST_DIR:-/etc/tarm/lists}"
AWG_ROUTE_TELEGRAM_CIDR="${AWG_ROUTE_TELEGRAM_CIDR:-/usr/share/tarm/telegram-cidr.txt}"
AWG_ROUTE_META_CIDR="${AWG_ROUTE_META_CIDR:-/usr/share/tarm/meta-cidr.txt}"
AWG_ROUTE_PRESET_DIR="${AWG_ROUTE_PRESET_DIR:-/usr/share/tarm/presets}"
AWG_ROUTE_FUNCTIONS="${AWG_ROUTE_FUNCTIONS:-/lib/functions.sh}"

awg_route_err() { echo "tarm: $*" >&2; }
awg_route_get() { uci -q get "$AWG_ROUTE_CONFIG.main.$1" 2>/dev/null || true; }

awg_route_load() {
	AWG_ENABLED="$(awg_route_get enabled)"
	AWG_IFACE="$(awg_route_get interface)"
	AWG_LAN="$(awg_route_get lan_device)"
	AWG_MARK="$(awg_route_get mark)"
	AWG_SOCKET_MARK="$(awg_route_get socket_mark)"
	AWG_TABLE="$(awg_route_get table)"
	AWG_DNS_SECTION="$(awg_route_get dnsmasq_section)"
	AWG_DNS_SERVER="$(awg_route_get dns_server)"
	[ -n "$AWG_IFACE" ] || AWG_IFACE=awg0
	[ -n "$AWG_LAN" ] || AWG_LAN=br-lan
	[ -n "$AWG_MARK" ] || AWG_MARK=0x700000
	[ -n "$AWG_SOCKET_MARK" ] || AWG_SOCKET_MARK=0x800000
	[ -n "$AWG_TABLE" ] || AWG_TABLE=700
	[ -n "$AWG_DNS_SECTION" ] || AWG_DNS_SECTION='@dnsmasq[0]'
	case "$AWG_IFACE:$AWG_LAN" in *[!a-zA-Z0-9_.:-]*) awg_route_err 'invalid interface name'; return 1;; esac
	case "$AWG_MARK" in
		0x*) case "${AWG_MARK#0x}" in ''|*[!0-9a-fA-F]*) awg_route_err 'invalid mark'; return 1;; esac;;
		*) awg_route_err 'invalid mark'; return 1;;
	esac
	case "$AWG_SOCKET_MARK" in
		0x*) case "${AWG_SOCKET_MARK#0x}" in ''|*[!0-9a-fA-F]*) awg_route_err 'invalid socket_mark'; return 1;; esac;;
		*) awg_route_err 'invalid socket_mark'; return 1;;
	esac
	[ "$((AWG_MARK))" -gt 0 ] && [ "$((AWG_MARK))" -le 4294967295 ] &&
		[ "$((AWG_SOCKET_MARK))" -ge 0 ] && [ "$((AWG_SOCKET_MARK))" -le 4294967295 ] || {
		awg_route_err 'marks must fit in 32 bits'; return 1;
	}
	[ "$((AWG_SOCKET_MARK & AWG_MARK))" -ne "$((AWG_MARK))" ] || { awg_route_err 'socket_mark must bypass the routing mark'; return 1; }
	case "$AWG_TABLE" in ''|*[!0-9]*) awg_route_err 'invalid table'; return 1;; esac
	if [ -n "$AWG_DNS_SERVER" ]; then
		case "$AWG_DNS_SERVER" in *[!0-9a-fA-F:.]*) awg_route_err 'dns_server must be an IP address'; return 1;; esac
	fi
	if [ -z "$AWG_ROUTE_DNS_CONF" ]; then
		local confdir
		confdir="$(uci -q get "dhcp.$AWG_DNS_SECTION.confdir" 2>/dev/null || true)"
		if [ -z "$confdir" ]; then
			confdir="$(sed -n 's/^conf-dir=//p' /var/etc/dnsmasq.conf.* 2>/dev/null | head -n 1)"
		fi
		[ -n "$confdir" ] || { awg_route_err 'dnsmasq conf-dir unavailable'; return 1; }
		AWG_ROUTE_DNS_CONF="${confdir%%,*}/tarm.conf"
	fi
}

awg_route_domains() {
	local kind="$1" raw path
	for raw in $(awg_route_get "${kind}_domain"); do
		printf '%s\n' "$raw"
	done
	for path in $(awg_route_get "${kind}_file"); do
		case "$path" in /etc/tarm/*) ;; *) awg_route_err "list outside /etc/tarm: $path"; return 1;; esac
		[ -f "$path" ] || { awg_route_err "missing list: $path"; return 1; }
		cat "$path"
	done
	if [ -f "$AWG_ROUTE_FUNCTIONS" ]; then
		. "$AWG_ROUTE_FUNCTIONS"
		config_load "$AWG_ROUTE_CONFIG"
		AWG_LIST_FAILED=0
		config_foreach awg_route_list_domains list "$kind"
		[ "$AWG_LIST_FAILED" = 0 ] || return 1
	fi
	[ "$kind" != vpn ] || awg_route_preset_domains
}

awg_route_preset_domains() {
	local slug path
	[ -f "$AWG_ROUTE_PRESET_DIR/index" ] || { awg_route_err 'offline preset index missing'; return 1; }
	while IFS= read -r slug || [ -n "$slug" ]; do
		case "$slug" in ''|*[!a-z0-9_]*) awg_route_err 'invalid offline preset name'; return 1;; esac
		[ "$(awg_route_get "preset_$slug")" = 1 ] || continue
		path="$AWG_ROUTE_PRESET_DIR/$slug.txt"
		[ -s "$path" ] || { awg_route_err "offline preset missing: $slug"; return 1; }
		cat "$path" || return 1
	done < "$AWG_ROUTE_PRESET_DIR/index"
}

awg_route_list_domains() {
	local section="$1" requested="$2" enabled route path url='' catalog='' manual
	config_get enabled "$section" enabled 1
	config_get route "$section" route vpn
	[ "$enabled" = 1 ] && [ "$route" = "$requested" ] || return 0
	case "$section" in *[!a-zA-Z0-9_-]*) awg_route_err "invalid list name: $section"; AWG_LIST_FAILED=1; return 1;; esac
	config_list_foreach "$section" domain awg_route_emit_domain || AWG_LIST_FAILED=1
	manual="$AWG_ROUTE_MANUAL_DIR/$section.txt"
	[ ! -f "$manual" ] || cat "$manual" || AWG_LIST_FAILED=1
	path="$AWG_ROUTE_LIST_DIR/$section.txt"
	if [ ! -s "$path" ]; then
		config_get url "$section" url
		config_get catalog "$section" catalog
		if [ -n "$url$catalog" ]; then
			awg_route_update_one "$section"
		fi
	fi
	if [ -s "$path" ]; then
		cat "$path" || AWG_LIST_FAILED=1
	elif [ -n "$url$catalog" ]; then
		awg_route_err "list unavailable: $section"
		AWG_LIST_FAILED=1
	fi
}

awg_route_emit_domain() { printf '%s\n' "$1"; }

awg_route_normalize() {
	local normalized_tmp
	normalized_tmp="$(mktemp)" || return 1
	if ! awk '
	{
		sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "");
		sub(/^\./, ""); sub(/\.$/, "");
		value=tolower($0);
		if (value == "") next;
		if (length(value) > 253 || value !~ /^[a-z0-9][a-z0-9._-]*[a-z0-9]$/ || value !~ /\./ || value ~ /\.\./) {
			printf "invalid domain: %s\n", value > "/dev/stderr"; bad=1; next;
		}
		print value;
	}
	END { if (bad) exit 1; }
	' > "$normalized_tmp"; then
		rm -f "$normalized_tmp"
		return 1
	fi
	sort -u "$normalized_tmp"
	rm -f "$normalized_tmp"
}

awg_route_classify() {
	local prefix="$1" kind
	: > "$prefix.domains"
	: > "$prefix.ip4"
	: > "$prefix.ip6"
	awk -v domains="$prefix.domains" -v ip4="$prefix.ip4" -v ip6="$prefix.ip6" '
	function invalid(value) { printf "invalid list entry: %s\n", value > "/dev/stderr"; bad=1 }
	function ipv4(value, parts, n, i) {
		n=split(value, parts, "."); if (n != 4) return 0;
		for (i=1; i<=4; i++) if (parts[i] !~ /^[0-9]+$/ || length(parts[i]) > 3 || parts[i]+0 > 255) return 0;
		return 1;
	}
	function ipv6(value, parts, n, i, compressed) {
		if (value !~ /^[0-9a-f:]+$/ || value !~ /:/ || value ~ /:::/) return 0;
		compressed=(index(value, "::") > 0);
		if (compressed && index(substr(value, index(value, "::")+2), "::") > 0) return 0;
		n=split(value, parts, ":");
		for (i=1; i<=n; i++) if (parts[i] != "" && (length(parts[i]) > 4 || parts[i] !~ /^[0-9a-f]+$/)) return 0;
		if (compressed) return n <= 9;
		return n == 8;
	}
	{
		sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); value=tolower($0);
		if (value == "") next;
		if (length(value) > 253 || value ~ /[ \t]/) { invalid(value); next; }
		n=split(value, fields, "/"); address=fields[1];
		if (n > 2 || (n == 2 && (fields[2] !~ /^[0-9]+$/ || length(fields[2]) > 3))) { invalid(value); next; }
		if (index(address, ":")) {
			if (!ipv6(address) || (n == 2 && fields[2]+0 > 128)) { invalid(value); next; }
			print value >> ip6; next;
		}
		if (n == 2 || address ~ /^[0-9.]+$/) {
			if (!ipv4(address) || (n == 2 && fields[2]+0 > 32)) { invalid(value); next; }
			print value >> ip4; next;
		}
		sub(/^\./, "", value); sub(/\.$/, "", value);
		if (length(value) > 253 || value !~ /^[a-z0-9][a-z0-9._-]*[a-z0-9]$/ || value !~ /\./ || value ~ /\.\./) { invalid(value); next; }
		print value >> domains;
	}
	END { if (bad) exit 1; }
	' || return 1
	for kind in domains ip4 ip6; do
		sort -u "$prefix.$kind" > "$prefix.$kind.sorted" || return 1
		mv "$prefix.$kind.sorted" "$prefix.$kind"
	done
}

awg_route_normalize_mixed() {
	local prefix="$AWG_ROUTE_STATE/mixed.$$" rc=0
	awg_route_classify "$prefix" || rc=1
	if [ "$rc" = 0 ]; then
		cat "$prefix.domains" "$prefix.ip4" "$prefix.ip6" | sort -u || rc=1
	fi
	rm -f "$prefix.domains" "$prefix.ip4" "$prefix.ip6" "$prefix.domains.sorted" "$prefix.ip4.sorted" "$prefix.ip6.sorted"
	return "$rc"
}

awg_route_prepare_lists() {
	local kind
	mkdir -p "$AWG_ROUTE_STATE"
	for kind in vpn direct; do
		awg_route_domains "$kind" > "$AWG_ROUTE_STATE/$kind.raw" || return 1
		awg_route_classify "$AWG_ROUTE_STATE/$kind.new" < "$AWG_ROUTE_STATE/$kind.raw" || return 1
		mv "$AWG_ROUTE_STATE/$kind.new.domains" "$AWG_ROUTE_STATE/$kind"
		mv "$AWG_ROUTE_STATE/$kind.new.ip4" "$AWG_ROUTE_STATE/$kind.ip4"
		mv "$AWG_ROUTE_STATE/$kind.new.ip6" "$AWG_ROUTE_STATE/$kind.ip6"
		rm -f "$AWG_ROUTE_STATE/$kind.raw"
	done
}

awg_route_write_dns() {
	mkdir -p "$(dirname "$AWG_ROUTE_DNS_CONF")"
	{
		while IFS= read -r domain; do
			[ -n "$domain" ] || continue
			printf 'nftset=/%s/4#inet#awg_route#vpn4,6#inet#awg_route#vpn6\n' "$domain"
			[ -z "$AWG_DNS_SERVER" ] || printf 'server=/%s/%s\n' "$domain" "$AWG_DNS_SERVER"
		done < "$AWG_ROUTE_STATE/vpn"
		while IFS= read -r domain; do
			[ -n "$domain" ] || continue
			printf 'nftset=/%s/4#inet#awg_route#direct4,6#inet#awg_route#direct6\n' "$domain"
		done < "$AWG_ROUTE_STATE/direct"
	} > "$AWG_ROUTE_DNS_CONF.new"
	mv "$AWG_ROUTE_DNS_CONF.new" "$AWG_ROUTE_DNS_CONF"
}

awg_route_write_nft() {
	local nft_file="$AWG_ROUTE_STATE/table.nft" mask
	mask="$(printf '0x%08x' "$((0xffffffff ^ AWG_MARK))")"
	if nft list table inet awg_route >/dev/null 2>&1; then
		: > "$nft_file"
		awg_route_update_static_set vpn4_static "$AWG_ROUTE_STATE/vpn.ip4" >> "$nft_file"
		awg_route_update_static_set vpn6_static "$AWG_ROUTE_STATE/vpn.ip6" >> "$nft_file"
		awg_route_update_static_set direct4_static "$AWG_ROUTE_STATE/direct.ip4" >> "$nft_file"
		awg_route_update_static_set direct6_static "$AWG_ROUTE_STATE/direct.ip6" >> "$nft_file"
		printf 'flush chain inet awg_route mark_lan\nflush chain inet awg_route nat_awg\n' >> "$nft_file"
	else
		cat > "$nft_file" <<EOF
table inet awg_route {
	set vpn4 { type ipv4_addr; flags timeout; timeout 1h; }
	set vpn6 { type ipv6_addr; flags timeout; timeout 1h; }
	set direct4 { type ipv4_addr; flags timeout; timeout 1h; }
	set direct6 { type ipv6_addr; flags timeout; timeout 1h; }
EOF
		awg_route_write_static_set vpn4_static ipv4_addr "$AWG_ROUTE_STATE/vpn.ip4" >> "$nft_file"
		awg_route_write_static_set vpn6_static ipv6_addr "$AWG_ROUTE_STATE/vpn.ip6" >> "$nft_file"
		awg_route_write_static_set direct4_static ipv4_addr "$AWG_ROUTE_STATE/direct.ip4" >> "$nft_file"
		awg_route_write_static_set direct6_static ipv6_addr "$AWG_ROUTE_STATE/direct.ip6" >> "$nft_file"
		cat >> "$nft_file" <<EOF
	chain mark_lan {
		type filter hook prerouting priority mangle; policy accept;
	}
	chain nat_awg {
		type nat hook postrouting priority srcnat; policy accept;
	}
}
EOF
	fi
	cat >> "$nft_file" <<EOF
	add rule inet awg_route mark_lan iifname "$AWG_LAN" ip daddr @direct4_static meta mark set meta mark & $mask ct mark set ct mark & $mask return
	add rule inet awg_route mark_lan iifname "$AWG_LAN" ip6 daddr @direct6_static meta mark set meta mark & $mask ct mark set ct mark & $mask return
	add rule inet awg_route mark_lan iifname "$AWG_LAN" ip daddr @direct4 meta mark set meta mark & $mask ct mark set ct mark & $mask return
	add rule inet awg_route mark_lan iifname "$AWG_LAN" ip6 daddr @direct6 meta mark set meta mark & $mask ct mark set ct mark & $mask return
	add rule inet awg_route mark_lan iifname "$AWG_LAN" ct mark & $AWG_MARK == $AWG_MARK meta mark set meta mark | $AWG_MARK
	add rule inet awg_route mark_lan iifname "$AWG_LAN" ip daddr @vpn4_static meta mark set meta mark | $AWG_MARK
	add rule inet awg_route mark_lan iifname "$AWG_LAN" ip6 daddr @vpn6_static meta mark set meta mark | $AWG_MARK
	add rule inet awg_route mark_lan iifname "$AWG_LAN" ip daddr @vpn4 meta mark set meta mark | $AWG_MARK
	add rule inet awg_route mark_lan iifname "$AWG_LAN" ip6 daddr @vpn6 meta mark set meta mark | $AWG_MARK
	add rule inet awg_route mark_lan iifname "$AWG_LAN" meta mark & $AWG_MARK == $AWG_MARK ct mark set ct mark | $AWG_MARK
	add rule inet awg_route nat_awg meta mark & $AWG_MARK == $AWG_MARK oifname "$AWG_IFACE" masquerade
EOF
	nft -c -f "$nft_file" || return 1
	nft -f "$nft_file"
}

awg_route_update_static_set() {
	local name="$1" source="$2"
	printf 'flush set inet awg_route %s\n' "$name"
	if [ -s "$source" ]; then
		printf 'add element inet awg_route %s { ' "$name"
		awk 'NR > 1 { printf ", " } { printf "%s", $0 } END { print " }" }' "$source"
	fi
}

awg_route_write_static_set() {
	local name="$1" type="$2" source="$3"
	printf '\tset %s { type %s; flags interval; auto-merge;' "$name" "$type"
	if [ -s "$source" ]; then
		printf ' elements = { '
		awk 'NR > 1 { printf ", " } { printf "%s", $0 } END { print " };" }' "$source"
	fi
	printf ' }\n'
}

awg_route_write_forward() {
	mkdir -p "$(dirname "$AWG_ROUTE_FW_INCLUDE")"
	printf 'meta mark & %s == %s oifname "%s" accept\n' "$AWG_MARK" "$AWG_MARK" "$AWG_IFACE" > "$AWG_ROUTE_FW_INCLUDE.new"
	mv "$AWG_ROUTE_FW_INCLUDE.new" "$AWG_ROUTE_FW_INCLUDE"
}

awg_route_routes() {
	local family rules expected dns_expected
	# Install the blackhole before any new fwmark rule. Never remove the rule
	# during apply: a marked packet must always have a route in this table.
	ip -4 route replace blackhole default table "$AWG_TABLE" metric 100 || return 1
	ip -6 route replace blackhole default table "$AWG_TABLE" metric 100 || return 1
	for family in -4 -6; do
		rules="$(ip "$family" rule show)" || return 1
		expected="fwmark $AWG_MARK/$AWG_MARK lookup $AWG_TABLE"
		if printf '%s\n' "$rules" | grep -q '^17000:'; then
			printf '%s\n' "$rules" | grep '^17000:' | grep -Fq "$expected" || {
				awg_route_err "existing priority 17000 rule differs for IPv${family#-}; stop before changing mark or table"
				return 1
			}
		else
			ip "$family" rule add priority 17000 fwmark "$AWG_MARK/$AWG_MARK" table "$AWG_TABLE" || return 1
		fi
		dns_expected=''
		if [ -n "$AWG_DNS_SERVER" ]; then
			case "$family:$AWG_DNS_SERVER" in
				-4:*:*) ;;
				-6:*:*) dns_expected="to $AWG_DNS_SERVER iif lo lookup $AWG_TABLE" ;;
				-4:*) dns_expected="to $AWG_DNS_SERVER iif lo lookup $AWG_TABLE" ;;
			esac
		fi
		if printf '%s\n' "$rules" | grep -q '^16999:'; then
			[ -n "$dns_expected" ] && printf '%s\n' "$rules" | grep '^16999:' | grep -Fq "$dns_expected" || {
				awg_route_err "existing priority 16999 DNS rule differs for IPv${family#-}; stop before changing VPN DNS"
				return 1
			}
		elif [ -n "$dns_expected" ]; then
			# Only dnsmasq's locally generated queries need this route. A
			# destination-only rule also catches unmarked LAN packets and sends
			# them to AWG, where fw4 rejects them.
			ip "$family" rule add priority 16999 iif lo to "$AWG_DNS_SERVER" table "$AWG_TABLE" || return 1
		fi
	done
	if [ "${AWG_ROUTE_FORCE_DOWN:-0}" != 1 ] && ip link show dev "$AWG_IFACE" >/dev/null 2>&1; then
		ip -4 route replace default dev "$AWG_IFACE" table "$AWG_TABLE" metric 10 || return 1
		ip -6 route replace default dev "$AWG_IFACE" table "$AWG_TABLE" metric 10 2>/dev/null || true
	else
		ip -4 route del default dev "$AWG_IFACE" table "$AWG_TABLE" metric 10 2>/dev/null || true
		ip -6 route del default dev "$AWG_IFACE" table "$AWG_TABLE" metric 10 2>/dev/null || true
	fi
}

awg_route_import() {
	local source="$1" tmp imported_dns
	[ -f "$source" ] || { awg_route_err 'configuration file missing'; return 1; }
	[ "$(wc -c < "$source")" -le 65536 ] || { awg_route_err 'configuration too large'; return 1; }
	umask 077
	mkdir -p "$(dirname "$AWG_ROUTE_TUNNEL")"
	tmp="$AWG_ROUTE_TUNNEL.new"
	tr -d '\r' < "$source" > "$tmp"
	if [ ! -s "$tmp" ]; then
		mv "$tmp" "$AWG_ROUTE_TUNNEL" || return 1
		chmod 600 "$AWG_ROUTE_TUNNEL"
		echo "Cleared $AWG_ROUTE_TUNNEL"
		return 0
	fi
	grep -q '^\[Interface\]' "$tmp" || { rm -f "$tmp"; awg_route_err 'missing [Interface]'; return 1; }
	grep -q '^\[Peer\]' "$tmp" || { rm -f "$tmp"; awg_route_err 'missing [Peer]'; return 1; }
	grep -qi '^[[:space:]]*PrivateKey[[:space:]]*=' "$tmp" || { rm -f "$tmp"; awg_route_err 'missing PrivateKey'; return 1; }
	grep -qi '^[[:space:]]*PublicKey[[:space:]]*=' "$tmp" || { rm -f "$tmp"; awg_route_err 'missing PublicKey'; return 1; }
	if ! (AWG_ROUTE_TUNNEL="$tmp"; awg_route_tunnel_prepare); then
		rm -f "$tmp"
		awg_route_err 'invalid tunnel configuration; previous profile kept'
		return 1
	fi
	mv "$tmp" "$AWG_ROUTE_TUNNEL" || return 1
	chmod 600 "$AWG_ROUTE_TUNNEL"
	imported_dns="$(sed -n 's/^[[:space:]]*DNS[[:space:]]*=[[:space:]]*\([^,[:space:]]*\).*/\1/p' "$AWG_ROUTE_TUNNEL" | head -n 1)"
	if [ -n "$imported_dns" ]; then
		case "$imported_dns" in *[!0-9a-fA-F:.]*) ;; *) uci set "$AWG_ROUTE_CONFIG.main.dns_server=$imported_dns"; uci commit "$AWG_ROUTE_CONFIG";; esac
	fi
	echo "Imported $AWG_ROUTE_TUNNEL"
}

awg_route_catalog_slug_valid() {
	case "$1" in ''|*[!a-z0-9_-]*) return 1;; esac
	[ "${#1}" -le 64 ]
}

awg_route_fetch_limited() {
	local output="$1" url="$2" max_bytes="$3" blocks
	# uclient-fetch has no body-size option. Limit the child process's output
	# before it can fill /tmp on a small router; retain the exact byte check.
	blocks=$(((max_bytes + 511) / 512 + 1))
	(ulimit -f "$blocks" || exit 1; uclient-fetch -q -O "$output" "$url") || return 1
	[ "$(wc -c < "$output")" -le "$max_bytes" ]
}

awg_route_catalog_fetch() {
	local root="$1" output="$2" work slug size total=0 count=0 skipped=0 rc=0 cidr=''
	awg_route_catalog_slug_valid "$root" || { awg_route_err "invalid catalog name: $root"; return 1; }
	work="$(mktemp -d "$AWG_ROUTE_STATE/catalog.XXXXXX")" || return 1
	printf '%s\n' "$root" > "$work/queue"
	: > "$work/seen"
	: > "$work/domains"
	while [ -s "$work/queue" ]; do
		slug="$(sed -n '1p' "$work/queue")"
		sed '1d' "$work/queue" > "$work/next"
		mv "$work/next" "$work/queue"
		awg_route_catalog_slug_valid "$slug" || { awg_route_err "invalid catalog include: $slug"; rc=1; break; }
		grep -Fqx "$slug" "$work/seen" && continue
		printf '%s\n' "$slug" >> "$work/seen"
		count=$((count + 1))
		[ "$count" -le 128 ] || { awg_route_err 'catalog has too many includes'; rc=1; break; }
		if ! awg_route_fetch_limited "$work/raw" "https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/$slug" 2097152; then
			awg_route_err "catalog download failed: $slug"
			rc=1
			break
		fi
		size="$(wc -c < "$work/raw")"
		total=$((total + size))
		[ "$total" -le 2097152 ] || { awg_route_err 'catalog exceeds 2 MiB download limit'; rc=1; break; }
		: > "$work/part"
		: > "$work/includes"
		awk -v domains="$work/part" -v includes="$work/includes" -v stats="$work/stats" '
		{
			sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "");
			if ($0 == "") next;
			split($0, fields, /[ \t]+/); item=tolower(fields[1]);
			if (item ~ /^include:/) { sub(/^include:/, "", item); print item >> includes; next; }
			if (item ~ /^(full|keyword|regexp):/) { skipped++; next; }
			sub(/^domain:/, "", item); sub(/^\*\./, "", item); sub(/^\./, "", item);
			if (item ~ /^[a-z0-9][a-z0-9._-]*[a-z0-9]$/ && item ~ /\./ && item !~ /\.\./)
				print item >> domains;
			else skipped++;
		}
		END { print skipped+0 > stats; }
		' "$work/raw" || { rc=1; break; }
		skipped=$((skipped + $(cat "$work/stats")))
		cat "$work/part" >> "$work/domains"
		cat "$work/includes" >> "$work/queue"
	done
	if [ "$rc" = 0 ]; then
		if [ ! -s "$work/domains" ] || ! awg_route_normalize < "$work/domains" > "$output" || [ "$(wc -c < "$output")" -gt 1048576 ]; then
			awg_route_err 'catalog has no supported domains or exceeds 1 MiB'
			rc=1
		fi
	fi
	case "$root" in
		telegram) cidr="$AWG_ROUTE_TELEGRAM_CIDR";;
		whatsapp) cidr="$AWG_ROUTE_META_CIDR";;
	esac
	if [ "$rc" = 0 ] && [ -n "$cidr" ]; then
		if [ ! -s "$cidr" ] || ! cat "$output" "$cidr" | awg_route_normalize_mixed > "$work/catalog.new"; then
			awg_route_err "$root CIDR snapshot missing or invalid"
			rc=1
		else
			mv "$work/catalog.new" "$output"
		fi
	fi
	[ "$skipped" = 0 ] || awg_route_err "catalog skipped $skipped unsupported entries"
	[ "$rc" = 0 ] || rm -f "$output"
	rm -f "$work/queue" "$work/next" "$work/seen" "$work/domains" "$work/raw" "$work/part" "$work/includes" "$work/stats" "$work/catalog.new"
	rmdir "$work" 2>/dev/null || true
	[ "$rc" = 0 ]
}

awg_route_update_one() {
	local section="$1" enabled url='' catalog='' path raw normalized size
	umask 077
	config_get enabled "$section" enabled 1
	config_get url "$section" url
	config_get catalog "$section" catalog
	[ "$enabled" = 1 ] && [ -n "$url$catalog" ] || return 0
	case "$section" in *[!a-zA-Z0-9_-]*) awg_route_err "invalid list name: $section"; AWG_UPDATE_FAILED=1; return 0;; esac
	path="$AWG_ROUTE_LIST_DIR/$section.txt"
	raw="$AWG_ROUTE_STATE/$section.download"
	normalized="$AWG_ROUTE_STATE/$section.normalized"
	if [ -n "$catalog" ]; then
		if ! awg_route_catalog_fetch "$catalog" "$normalized"; then
			AWG_UPDATE_FAILED=1
			return 0
		fi
	else
		case "$url" in https://*) ;; *) awg_route_err "list URL must use HTTPS: $section"; AWG_UPDATE_FAILED=1; return 0;; esac
		if ! awg_route_fetch_limited "$raw" "$url" 1048576; then
			awg_route_err "download failed: $section"
			AWG_UPDATE_FAILED=1
			return 0
		fi
		size="$(wc -c < "$raw")"
		if [ "$size" -gt 1048576 ] || ! awg_route_normalize_mixed < "$raw" > "$normalized" || [ ! -s "$normalized" ]; then
			awg_route_err "invalid or oversized list: $section"
			AWG_UPDATE_FAILED=1
			return 0
		fi
	fi
	[ -s "$normalized" ] || { awg_route_err "empty list: $section"; AWG_UPDATE_FAILED=1; return 0; }
	if [ -n "${AWG_UPDATE_STAGE:-}" ]; then
		mv "$normalized" "$AWG_UPDATE_STAGE/$section.txt" || { AWG_UPDATE_FAILED=1; return 0; }
		printf '%s\n' "$section" >> "$AWG_UPDATE_STAGE/sections"
		rm -f "$raw"
		return 0
	fi
	mkdir -p "$(dirname "$path")"
	mv "$normalized" "$path" || AWG_UPDATE_FAILED=1
	rm -f "$raw"
}

awg_route_update() {
	local section path stage committed='' rollback_failed=0
	umask 077
	awg_route_load || return 1
	AWG_UPDATE_FAILED=0
	mkdir -p "$AWG_ROUTE_STATE"
	AWG_UPDATE_STAGE="$(mktemp -d "$AWG_ROUTE_STATE/update.XXXXXX")" || return 1
	: > "$AWG_UPDATE_STAGE/sections"
	. "$AWG_ROUTE_FUNCTIONS"
	config_load "$AWG_ROUTE_CONFIG"
	config_foreach awg_route_update_one list
	if [ "$AWG_UPDATE_FAILED" != 0 ]; then
		rm -rf "$AWG_UPDATE_STAGE"
		AWG_UPDATE_STAGE=''
		return 1
	fi
	stage="$AWG_UPDATE_STAGE"
	mkdir -p "$AWG_ROUTE_LIST_DIR" || { rm -rf "$stage"; AWG_UPDATE_STAGE=''; return 1; }
	# Prepare every replacement and backup on the destination filesystem first.
	# A failed download or copy cannot expose a partly updated generation.
	while IFS= read -r section; do
		path="$AWG_ROUTE_LIST_DIR/$section.txt"
		rm -f "$path.tarm-new" "$path.tarm-backup"
		cp "$stage/$section.txt" "$path.tarm-new" || AWG_UPDATE_FAILED=1
		if [ -e "$path" ]; then cp -p "$path" "$path.tarm-backup" || AWG_UPDATE_FAILED=1; else : > "$stage/$section.absent"; fi
		[ "$AWG_UPDATE_FAILED" = 0 ] || break
	done < "$stage/sections"
	if [ "$AWG_UPDATE_FAILED" = 0 ]; then
		while IFS= read -r section; do
			path="$AWG_ROUTE_LIST_DIR/$section.txt"
			mv "$path.tarm-new" "$path" || { AWG_UPDATE_FAILED=1; break; }
			committed="$committed $section"
		done < "$stage/sections"
	fi
	if [ "$AWG_UPDATE_FAILED" != 0 ]; then
		for section in $committed; do
			path="$AWG_ROUTE_LIST_DIR/$section.txt"
			if [ -e "$stage/$section.absent" ]; then rm -f "$path" || rollback_failed=1; else mv "$path.tarm-backup" "$path" || rollback_failed=1; fi
		done
		if [ "$rollback_failed" != 0 ]; then
			awg_route_err 'list rollback failed; backup files retained'
			AWG_UPDATE_STAGE=''
			return 1
		fi
	fi
	while IFS= read -r section; do
		path="$AWG_ROUTE_LIST_DIR/$section.txt"
		rm -f "$path.tarm-new" "$path.tarm-backup"
	done < "$stage/sections"
	rm -rf "$stage"
	AWG_UPDATE_STAGE=''
	[ "$AWG_UPDATE_FAILED" = 0 ] || { awg_route_err 'list update failed; previous generation restored'; return 1; }
	[ "$AWG_ENABLED" = 1 ] || return 0
	awg_route_apply
}

awg_route_catalog_add() {
	local slug="$1" section current existing normalized target
	awg_route_catalog_slug_valid "$slug" || { awg_route_err 'invalid catalog name'; return 1; }
	[ "${#slug}" -le 48 ] || { awg_route_err 'catalog name too long'; return 1; }
	section="catalog_$(printf '%s' "$slug" | tr '-' '_')"
	current="$(uci -q get "$AWG_ROUTE_CONFIG.$section" 2>/dev/null || true)"
	if [ -n "$current" ]; then
		existing="$(uci -q get "$AWG_ROUTE_CONFIG.$section.catalog" 2>/dev/null || true)"
		[ "$current" = list ] && [ "$existing" = "$slug" ] || { awg_route_err "section already exists: $section"; return 1; }
	fi
	mkdir -p "$AWG_ROUTE_STATE"
	normalized="$AWG_ROUTE_STATE/$section.catalog.new"
	awg_route_catalog_fetch "$slug" "$normalized" || return 1
	uci set "$AWG_ROUTE_CONFIG.$section=list"
	uci set "$AWG_ROUTE_CONFIG.$section.enabled=1"
	uci set "$AWG_ROUTE_CONFIG.$section.route=vpn"
	uci set "$AWG_ROUTE_CONFIG.$section.catalog=$slug"
	uci commit "$AWG_ROUTE_CONFIG"
	target="$AWG_ROUTE_LIST_DIR/$section.txt"
	mkdir -p "$(dirname "$target")"
	mv "$normalized" "$target"
	if [ "$(awg_route_get enabled)" = 1 ]; then awg_route_apply || return 1; fi
	printf 'Catalog %s added as list %s\n' "$slug" "$section"
}

awg_route_import_list() {
	local section="$1" mode="$2" current target prepared normalized count
	case "$section" in ''|*[!a-zA-Z0-9_-]*) awg_route_err 'invalid list name'; return 1;; esac
	case "$mode" in append|replace) ;; *) awg_route_err 'mode must be append or replace'; return 1;; esac
	[ "$(uci -q get "$AWG_ROUTE_CONFIG.$section" 2>/dev/null || true)" = list ] || { awg_route_err "unknown list: $section"; return 1; }
	[ -f "$AWG_ROUTE_IMPORT" ] && [ "$(wc -c < "$AWG_ROUTE_IMPORT")" -le 262144 ] || { awg_route_err 'import file missing or exceeds 256 KiB'; return 1; }
	mkdir -p "$AWG_ROUTE_STATE" "$AWG_ROUTE_MANUAL_DIR"
	target="$AWG_ROUTE_MANUAL_DIR/$section.txt"
	prepared="$AWG_ROUTE_STATE/$section.import.raw"
	normalized="$AWG_ROUTE_STATE/$section.import.new"
	if [ "$mode" = append ] && [ -f "$target" ]; then cat "$target" > "$prepared"; else : > "$prepared"; fi
	awk '
	{
		sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "");
		if ($0 == "") next;
		line=tolower($0);
		if (line ~ /^https?:\/\//) { sub(/^https?:\/\//, "", line); sub(/[\/?].*$/, "", line); sub(/:[0-9]+$/, "", line); }
		sub(/^domain:/, "", line); sub(/^\*\./, "", line);
		print line;
	}
	' "$AWG_ROUTE_IMPORT" >> "$prepared" || return 1
	if ! awg_route_normalize_mixed < "$prepared" > "$normalized" || [ "$(wc -c < "$normalized")" -gt 1048576 ]; then
		awg_route_err 'invalid or oversized list; existing list kept'
		return 1
	fi
	chmod 600 "$normalized"
	mv "$normalized" "$target"
	: > "$AWG_ROUTE_IMPORT"
	count="$(wc -l < "$target")"
	printf 'Imported %s entries into %s\n' "$count" "$section"
	awg_route_load || return 1
	[ "$AWG_ENABLED" = 1 ] || return 0
	awg_route_apply
}

awg_route_tunnel_prepare() {
	local section='' line key value token prefix
	AWG_ADDRESSES=''
	AWG_MTU=''
	[ -f "$AWG_ROUTE_TUNNEL" ] || return 1
	umask 077
	mkdir -p "$AWG_ROUTE_STATE"
	: > "$AWG_ROUTE_STATE/tunnel.setconf"
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			'[Interface]'|'[Peer]') section="$line"; printf '%s\n' "$line" >> "$AWG_ROUTE_STATE/tunnel.setconf"; continue;;
			'['*']') awg_route_err "unsupported tunnel section: $line"; return 1;;
			''|'#'*) continue;;
		esac
		case "$line" in *=*) ;; *) awg_route_err "invalid tunnel line"; return 1;; esac
		key="${line%%=*}"
		value="${line#*=}"
		key="$(printf '%s' "$key" | tr -d ' \t')"
		value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
		case "$section:$key" in
			'[Interface]:Address')
				for token in $(printf '%s' "$value" | tr ',' ' '); do
					case "$token" in *[!0-9a-fA-F:.\/]*) awg_route_err 'invalid Address'; return 1;; esac
					prefix="$AWG_ROUTE_STATE/address.$$"
					if ! printf '%s\n' "$token" | awg_route_classify "$prefix" ||
						[ -s "$prefix.domains" ] ||
						{ [ ! -s "$prefix.ip4" ] && [ ! -s "$prefix.ip6" ]; }; then
						rm -f "$prefix.domains" "$prefix.ip4" "$prefix.ip6"
						awg_route_err 'invalid Address'; return 1
					fi
					rm -f "$prefix.domains" "$prefix.ip4" "$prefix.ip6"
					AWG_ADDRESSES="$AWG_ADDRESSES $token"
				 done;;
			'[Interface]:MTU')
				case "$value" in ''|*[!0-9]*) awg_route_err 'invalid MTU'; return 1;; esac
				[ "$value" -ge 1280 ] && [ "$value" -le 9000 ] || { awg_route_err 'MTU outside 1280–9000'; return 1; }
				AWG_MTU="$value";;
			'[Interface]:DNS'|'[Interface]:Table') ;;
			'[Interface]:PreUp'|'[Interface]:PostUp'|'[Interface]:PreDown'|'[Interface]:PostDown'|'[Interface]:SaveConfig')
				awg_route_err "unsupported hook: $key"; return 1;;
			*) printf '%s = %s\n' "$key" "$value" >> "$AWG_ROUTE_STATE/tunnel.setconf";;
		esac
	done < "$AWG_ROUTE_TUNNEL"
	[ -n "$AWG_ADDRESSES" ] || { awg_route_err 'tunnel Address missing'; return 1; }
}

awg_route_tunnel_up() {
	[ -s "$AWG_ROUTE_TUNNEL" ] || { awg_route_tunnel_down; return 0; }
	awg_route_tunnel_prepare || return 1
	if ! ip link show dev "$AWG_IFACE" >/dev/null 2>&1; then
		ip link add dev "$AWG_IFACE" type amneziawg || return 1
	fi
	awg setconf "$AWG_IFACE" "$AWG_ROUTE_STATE/tunnel.setconf" || return 1
	# Outer UDP packets must bypass the policy rule used for LAN traffic.
	awg set "$AWG_IFACE" fwmark "$AWG_SOCKET_MARK" || return 1
	# A new client profile may have a different Address. Remove addresses from
	# the previous profile before assigning the current one.
	ip address flush dev "$AWG_IFACE" || return 1
	for address in $AWG_ADDRESSES; do
		ip address replace "$address" dev "$AWG_IFACE" || return 1
	done
	[ -z "$AWG_MTU" ] || ip link set mtu "$AWG_MTU" dev "$AWG_IFACE"
	ip link set up dev "$AWG_IFACE"
}

awg_route_tunnel_down() {
	ip link del dev "$AWG_IFACE" 2>/dev/null || true
}

awg_route_apply() {
	awg_route_load || return 1
	[ "$AWG_ENABLED" = 1 ] || { awg_route_stop; return 0; }
	command -v dnsmasq >/dev/null || { awg_route_err 'dnsmasq missing'; return 1; }
	dnsmasq --version | grep 'Compile time options:' | grep -Eq '(^|[[:space:]])nftset([[:space:]]|$)' || { awg_route_err 'dnsmasq lacks nftset support'; return 1; }
	awg_route_prepare_lists || return 1
	[ ! -s "$AWG_ROUTE_TUNNEL" ] || awg_route_tunnel_prepare || return 1
	(AWG_ROUTE_FORCE_DOWN=1; awg_route_routes) || return 1
	awg_route_write_nft || { awg_route_err 'nft apply failed; VPN routes remain blocked'; return 1; }
	awg_route_write_forward || return 1
	awg_route_tunnel_up || { awg_route_err 'tunnel setup failed; VPN routes remain blocked'; return 1; }
	awg_route_routes || return 1
	awg_route_write_dns || return 1
	/etc/init.d/firewall reload || { awg_route_err 'firewall reload failed'; return 1; }
	/etc/init.d/dnsmasq restart || { awg_route_err 'dnsmasq restart failed'; return 1; }
}

awg_route_cleanup_policy() {
	local family
	for family in -4 -6; do
		ip "$family" rule del priority 17000 fwmark "$AWG_MARK/$AWG_MARK" table "$AWG_TABLE" 2>/dev/null || true
		if [ -n "$AWG_DNS_SERVER" ]; then
			case "$family:$AWG_DNS_SERVER" in
				-4:*:*) ;;
				-6:*:*|-4:*)
					ip "$family" rule del priority 16999 iif lo to "$AWG_DNS_SERVER" table "$AWG_TABLE" 2>/dev/null || true
					# Also clean up the destination-only rule from older installs.
					ip "$family" rule del priority 16999 to "$AWG_DNS_SERVER" table "$AWG_TABLE" 2>/dev/null || true ;;
			esac
		fi
		ip "$family" route del default dev "$AWG_IFACE" table "$AWG_TABLE" metric 10 2>/dev/null || true
		ip "$family" route del blackhole default table "$AWG_TABLE" metric 100 2>/dev/null || true
	done
}

awg_route_stop() {
	awg_route_load || return 1
	rm -f "$AWG_ROUTE_DNS_CONF" "$AWG_ROUTE_FW_INCLUDE"
	nft delete table inet awg_route 2>/dev/null || true
	awg_route_cleanup_policy
	awg_route_tunnel_down
	/etc/init.d/firewall reload
	/etc/init.d/dnsmasq restart
}

awg_route_check() {
	local needle="$1" kind domain match='direct'
	[ -n "$needle" ] || { awg_route_err 'domain required'; return 2; }
	awg_route_prepare_lists || return 1
	for kind in direct vpn; do
		while IFS= read -r domain; do
			case "$needle" in "$domain"|*."$domain")
				[ "$kind" = direct ] && { echo "direct ($domain)"; return 0; }
				match="vpn ($domain)";;
			esac
		done < "$AWG_ROUTE_STATE/$kind"
	done
	echo "$match"
}

awg_route_status() {
	awg_route_load
	printf 'enabled=%s interface=%s\n' "$AWG_ENABLED" "$AWG_IFACE"
	ip link show dev "$AWG_IFACE" 2>&1 || true
	nft list table inet awg_route 2>&1 || true
}

awg_route_status_brief() {
	local link=down handshake=0 rx=0 tx=0 now flags
	awg_route_load || return 1
	flags="$(ip -o link show dev "$AWG_IFACE" 2>/dev/null |
		sed -n 's/^[^<]*<\([^>]*\)>.*/,\1,/p')"
	case "$flags" in *,UP,*)
		link=up
		handshake="$(awg show "$AWG_IFACE" latest-handshakes 2>/dev/null |
			awk '{ if ($2 > latest) latest = $2 } END { printf "%.0f", latest + 0 }')"
		set -- $(awg show "$AWG_IFACE" transfer 2>/dev/null |
			awk '{ received += $2; sent += $3 } END { printf "%.0f %.0f", received, sent }')
		rx="${1:-0}"
		tx="${2:-0}"
		;;
	esac
	now="$(date +%s)"
	printf 'enabled=%s link=%s handshake=%s rx=%s tx=%s now=%s\n' \
		"$AWG_ENABLED" "$link" "$handshake" "$rx" "$tx" "$now"
}
