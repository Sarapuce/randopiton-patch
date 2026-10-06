#!/usr/bin/env python3
"""Replace the Google Maps API key in a binary AndroidManifest.xml.

Usage: replace_maps_key.py <AndroidManifest.xml> <old_key> <new_key>

The binary manifest stores strings as UTF-16LE, so both keys are encoded that
way before searching. The old key must appear exactly once, and both keys must
have the same length so the string pool offsets stay valid.
"""
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(path, 'rb').read()
o, n = old.encode('utf-16-le'), new.encode('utf-16-le')
if data.count(o) != 1:
    sys.stderr.write("error: original Google Maps key not found in the manifest.\n")
    sys.exit(1)
open(path, 'wb').write(data.replace(o, n))
