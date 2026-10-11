#!/usr/bin/env python3
"""Check APK kernel ABI parsing before the installer downloads anything."""

import os
from pathlib import Path
import subprocess
import tempfile


INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"
OFFICIAL_ABI = "6.12.94~35fb64ea09ee15c2f267bd5436b7f178-r1"
CUSTOM_ABI = "6.12.94~6f5dc6e6d88b5e60edb2defcd1d7e81c-r1"


def run_installer(abi):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        release = root / "openwrt_release"
        release.write_text(
            "DISTRIB_TARGET='ramips/mt7621'\n"
            "DISTRIB_ARCH='mipsel_24kc'\n"
            "DISTRIB_RELEASE='25.12.5'\n"
        )
        commands = {
            "uname": "#!/bin/sh\necho 6.12.94\n",
            "apk": (
                "#!/bin/sh\n"
                "[ \"$1\" = list ] || exit 2\n"
                "printf 'kernel-%s mipsel_24kc {base} [installed]\\n' \"$MOCK_KERNEL_ABI\"\n"
            ),
            "uclient-fetch": "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$MOCK_FETCH_LOG\"\nexit 1\n",
            "sleep": "#!/bin/sh\nexit 0\n",
        }
        for name, source in commands.items():
            executable = bin_dir / name
            executable.write_text(source)
            executable.chmod(0o755)
        fetch_log = root / "fetch.log"
        env = os.environ.copy()
        env.update(
            PATH=f"{bin_dir}:{env['PATH']}",
            TARM_RELEASE_FILE=str(release),
            MOCK_KERNEL_ABI=abi,
            MOCK_FETCH_LOG=str(fetch_log),
        )
        result = subprocess.run(
            ["sh", str(INSTALLER)], env=env, capture_output=True, text=True
        )
        return result, fetch_log.read_text() if fetch_log.exists() else ""


result, fetched = run_installer(OFFICIAL_ABI)
assert result.returncode != 0, result.stdout
assert "kernel ABI mismatch" not in result.stderr, result.stderr
assert "openwrt-25.12.5-ramips-mt7621.tar.gz" in fetched, fetched

result, fetched = run_installer(CUSTOM_ABI)
assert result.returncode != 0, result.stdout
assert f"found {CUSTOM_ABI}" in result.stderr, result.stderr
assert not fetched, fetched

print("installer ABI tests passed")
