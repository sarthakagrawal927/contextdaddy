#!/usr/bin/env python3
"""Prepare a signed appcast from an already notarized DMG. Does not deploy."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET
import sparkle_support

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("release_directory", type=Path)
parser.add_argument("output", type=Path, help="New directory; must not already exist")
args = parser.parse_args()
sparkle_support.configuration()
receipt = json.loads((args.release_directory / "release-receipt.json").read_text())
if not all(receipt.get(key) for key in ["notarized", "stapled", "signed"]):
    raise SystemExit("Only signed, notarized and stapled releases can enter the appcast")
sources = list(args.release_directory.glob("*.dmg"))
if len(sources) != 1:
    raise SystemExit("Expected exactly one release DMG")
source = sources[0]
if hashlib.sha256(source.read_bytes()).hexdigest() != receipt["dmgSha256"]:
    raise SystemExit("Release checksum mismatch")
args.output.mkdir(parents=True, exist_ok=False)
filename = f"storagedaddy-{receipt['version']}-build{receipt['build']}-arm64.dmg"
shutil.copy2(source, args.output / filename)
tool = sparkle_support.ROOT / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
subprocess.run([str(tool), "--account", "storagedaddy-updates", "--download-url-prefix",
                "https://storagedaddy.significanthobbies.com/updates/", str(args.output)], check=True)
feed = args.output / "appcast.xml"
root = ET.parse(feed).getroot()
enclosures = root.findall("./channel/item/enclosure")
if not enclosures:
    raise SystemExit("Empty update feed: do not publish")
for enclosure in enclosures:
    if not enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"):
        raise SystemExit("Unsigned enclosure: do not publish")
print(feed)
