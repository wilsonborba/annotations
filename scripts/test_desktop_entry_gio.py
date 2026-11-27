#!/usr/bin/env python3
"""Exercise generated user desktop entries through the installed GIO parser."""

import os
import subprocess
import sys
import time
from pathlib import Path

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio


installer, template, fixture_root = map(Path, sys.argv[1:])
fixture_root.mkdir(parents=True, exist_ok=True)
labels = (
    "ordinary",
    "space path",
    "dollar$path",
    "amp&path",
    'quote"path',
    r"back\slash",
)

for label in labels:
    root = fixture_root / label
    data_home = root / ("data & $ \" \\home" if label != "ordinary" else "data")
    bin_home = root / ("bin " + label)
    data_home.mkdir(parents=True)
    bin_home.mkdir(parents=True)
    launcher = bin_home / "annotations"
    marker = root / "launch marker"
    launcher.write_text(
        "#!/bin/sh\nprintf '%s' launched > \"$NATIVE_REVIEW_MARKER\"\n",
        encoding="utf-8",
    )
    launcher.chmod(0o755)
    env = {
        **os.environ,
        "HOME": str(root),
        "XDG_DATA_HOME": str(data_home),
        "XDG_BIN_HOME": str(bin_home),
    }
    subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; prepare_desktop_entry "$2"; activate_desktop_entry',
            "_",
            str(installer),
            str(template),
        ],
        env=env,
        check=True,
    )
    desktop = data_home / "applications/com.asodya.annotations.desktop"
    app = Gio.DesktopAppInfo.new_from_filename(str(desktop))
    if app is None:
        raise SystemExit(f"GIO rejected generated desktop entry for {label!r}")
    if app.get_executable() is None:
        raise SystemExit(f"GIO found no executable for {label!r}")
    os.environ["NATIVE_REVIEW_MARKER"] = str(marker)
    if not app.launch([], None):
        raise SystemExit(f"GIO did not launch generated entry for {label!r}")
    deadline = time.monotonic() + 3
    while not marker.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if not marker.is_file() or marker.read_text(encoding="utf-8") != "launched":
        raise SystemExit(f"generated entry did not execute its exact launcher for {label!r}")
    if "TryExec=" in desktop.read_text(encoding="utf-8"):
        raise SystemExit("generated entry retained an invalid TryExec command line")
    print(f"GIO parse and launch passed: {label}")
