#!/usr/bin/env python3
"""Package the driver folder into a .c4z and sanity-check it first.

Usage:  python3 control4/tools/build_c4z.py [--driver shield_bridge|roku_bridge] [--out FILE]

A .c4z is a zip with driver.xml at its root. Composer rejects malformed XML
silently, so the XML is parsed here, every controller://driver/<name>/... icon
path in it is checked against the files being packaged, and the Lua file is at
least loaded by luac when one is on the PATH.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DRIVERS_ROOT = os.path.dirname(HERE)


def check(driver_dir, driver_name):
    xml_path = os.path.join(driver_dir, "driver.xml")
    tree = ET.parse(xml_path)  # raises on malformed XML
    root = tree.getroot()
    problems = []

    name = root.findtext("name")
    if not name:
        problems.append("driver.xml has no <name>")

    script = root.find("./config/script")
    if script is None or not os.path.exists(os.path.join(driver_dir, script.get("file", ""))):
        problems.append("config/script file missing")

    doc = root.find("./config/documentation")
    if doc is not None and not os.path.exists(os.path.join(driver_dir, doc.get("file", ""))):
        problems.append("documentation file missing: %s" % doc.get("file"))

    for tag in ("small", "large"):
        el = root.find(tag)
        if el is not None and not os.path.exists(os.path.join(driver_dir, el.text or "")):
            problems.append("%s icon missing: %s" % (tag, el.text))

    raw = open(xml_path, encoding="utf-8").read()
    for m in re.finditer(r"controller://driver/([^/]+)/([^<\s]+)", raw):
        if m.group(1) != driver_name:
            problems.append("icon path uses driver name %r, expected %r" % (m.group(1), driver_name))
        if not os.path.exists(os.path.join(driver_dir, m.group(2))):
            problems.append("referenced icon missing: %s" % m.group(2))

    for proxy in root.findall("./proxies/proxy"):
        if proxy.text not in ("media_service", "media_player"):
            problems.append("unexpected proxy type %s" % proxy.text)

    luac = shutil.which("luac5.1") or shutil.which("luac")
    if luac:
        r = subprocess.run([luac, "-p", os.path.join(driver_dir, "driver.lua")], capture_output=True, text=True)
        if r.returncode != 0:
            problems.append("driver.lua syntax: " + r.stderr.strip())
    return problems


def build(driver_dir, out_path):
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    count = 0
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, _dirs, files in os.walk(driver_dir):
            for f in sorted(files):
                if f.startswith(".") or f.endswith(".pyc"):
                    continue
                full = os.path.join(folder, f)
                rel = os.path.relpath(full, driver_dir).replace(os.sep, "/")
                z.write(full, rel)
                count += 1
    return count


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--driver", default="shield_bridge", help="driver folder name under control4/")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    driver_dir = os.path.join(DRIVERS_ROOT, args.driver)
    out = args.out or os.path.join(os.path.dirname(DRIVERS_ROOT), "dist", args.driver + ".c4z")

    problems = check(driver_dir, args.driver)
    if problems:
        for p in problems:
            print("ERROR:", p)
        return 1
    n = build(driver_dir, out)
    print("wrote %s (%d files, %d bytes)" % (out, n, os.path.getsize(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
