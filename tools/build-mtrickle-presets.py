#!/usr/bin/env python3
"""Convert selected groups from a MagiTrickle export into offline TARM lists."""

import argparse
import ipaddress
import json
import re
import sys
from pathlib import Path


GROUPS = {
    "Akamai": "akamai",
    "AWS": "aws",
    "Azure": "azure",
    "Cloudflare": "cloudflare",
    "DigitalOcean": "digitalocean",
    "Google Cloud": "google_cloud",
    "Hetzner": "hetzner",
    "Oracle": "oracle",
    "OVH": "ovh",
    "YouTube": "youtube",
    "Telegram": "telegram",
    "Meta (WA+FB+Instagram)": "meta",
    "X (Twitter)": "x_twitter",
    "Discord": "discord",
    "TikTok": "tiktok",
    "Roblox": "roblox",
    "Supercell": "supercell",
    "GeoBlock": "geoblock",
}


def convert(group):
    domains = set()
    ipv4 = []
    ipv6 = []
    for rule in group["rules"]:
        if not rule.get("enable", False):
            continue
        value = rule["rule"].strip().lower()
        kind = rule["type"]
        if kind == "namespace":
            if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*[a-z0-9]", value) or "." not in value or ".." in value:
                # MagiTrickle also accepts bare keywords. TARM only routes
                # domain suffixes, so a bare keyword cannot be represented.
                if "." not in value:
                    print(f"skipping bare keyword in {group['name']}: {value}", file=sys.stderr)
                    continue
                raise ValueError(f"invalid domain: {value}")
            domains.add(value)
        elif kind in ("subnet", "subnet6"):
            network = ipaddress.ip_network(value, strict=False)
            if network.version != (4 if kind == "subnet" else 6):
                raise ValueError(f"unexpected address family: {value}")
            (ipv4 if network.version == 4 else ipv6).append(network)
        else:
            raise ValueError(f"unsupported rule type: {kind}")
    collapsed = list(ipaddress.collapse_addresses(ipv4)) + list(ipaddress.collapse_addresses(ipv6))
    return sorted(domains) + [str(network) for network in collapsed]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="MagiTrickle .mtrickle JSON export")
    parser.add_argument("output", type=Path, help="TARM preset directory")
    args = parser.parse_args()
    groups = {group["name"]: group for group in json.loads(args.input.read_text())["groups"]}
    missing = GROUPS.keys() - groups.keys()
    if missing:
        raise SystemExit(f"missing groups: {', '.join(sorted(missing))}")
    converted = {}
    for name, slug in GROUPS.items():
        entries = convert(groups[name])
        if not entries:
            raise SystemExit(f"empty group: {name}")
        converted[slug] = entries
    args.output.mkdir(parents=True, exist_ok=True)
    for slug in ("flathub", "warthunder", "custom_sites"):
        (args.output / f"{slug}.txt").unlink(missing_ok=True)
    for slug, entries in converted.items():
        (args.output / f"{slug}.txt").write_text("\n".join(entries) + "\n")
        print(f"{slug}: {len(entries)} entries")
    (args.output / "index").write_text("\n".join(GROUPS.values()) + "\n")


if __name__ == "__main__":
    main()
