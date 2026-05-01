#!/usr/bin/env python3
"""Insert a new <item> into a Sparkle appcast.xml.

Reads the existing appcast, parses the `sign_update` output, and writes
back the file with the new entry placed first inside <channel> (newest
release at the top — matches RSS conventions; Sparkle picks by version
regardless of order).

Usage (typically invoked by bin/make_release.sh):

    update_appcast.py \\
        --appcast        appcast.xml \\
        --short-version  0.1.0-b8 \\
        --build          42 \\
        --enclosure-url  https://github.com/.../SipClient-0.1.0-b8.zip \\
        --asset          build/release/0.1.0-b8/SipClient-0.1.0-b8.zip \\
        --sign-output    'sparkle:edSignature="..." length="..."' \\
        --notes-html     '<ul><li>Fix RTP jitter</li></ul>'
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.dom import minidom


def parse_sign_output(s: str) -> dict[str, str]:
    """Pull key="value" pairs out of `sign_update`'s output string.

    sign_update prints something like:
        sparkle:edSignature="abc..." length="12345"
    """
    pairs = re.findall(r'([\w:]+)="([^"]*)"', s)
    return dict(pairs)


def rfc822_now() -> str:
    return datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--appcast", required=True, type=Path)
    p.add_argument("--short-version", required=True)
    p.add_argument("--build", required=True,
                   help="CFBundleVersion — Sparkle's comparison version")
    p.add_argument("--enclosure-url", required=True)
    p.add_argument("--asset", required=True, type=Path,
                   help="Path to the .zip — used for length= when sign_update "
                        "didn't include it")
    p.add_argument("--sign-output", required=True,
                   help="Raw output from `sign_update -f <key> <zip>`")
    p.add_argument("--notes-html", default="",
                   help="Release notes (HTML; will be wrapped in CDATA)")
    p.add_argument("--min-system-version", default="14.0",
                   help="Minimum macOS the build supports")
    args = p.parse_args()

    if not args.appcast.exists():
        print(f"error: appcast not found: {args.appcast}", file=sys.stderr)
        return 2
    if not args.asset.exists():
        print(f"error: asset not found: {args.asset}", file=sys.stderr)
        return 2

    sig = parse_sign_output(args.sign_output)
    ed_signature = sig.get("sparkle:edSignature")
    if not ed_signature:
        print("error: --sign-output did not contain sparkle:edSignature",
              file=sys.stderr)
        return 3
    length = sig.get("length") or str(os.path.getsize(args.asset))

    dom = minidom.parse(str(args.appcast))
    channels = dom.getElementsByTagName("channel")
    if not channels:
        print("error: appcast has no <channel>", file=sys.stderr)
        return 4
    channel = channels[0]

    # Drop any existing <item> entries whose <sparkle:version> matches
    # the build number we're inserting — keeps the appcast clean when
    # the release script is re-run for the same version (e.g. after a
    # transient notary failure).
    removed = 0
    for existing in list(channel.getElementsByTagName("item")):
        ver_nodes = existing.getElementsByTagName("sparkle:version")
        if not ver_nodes:
            continue
        first = ver_nodes[0].firstChild
        if first is None:
            continue
        if first.nodeValue.strip() == args.build:
            channel.removeChild(existing)
            removed += 1
    if removed:
        print(f"  removed {removed} existing entry/entries for build {args.build}")

    item = dom.createElement("item")

    title = dom.createElement("title")
    title.appendChild(dom.createTextNode(f"Version {args.short_version}"))
    item.appendChild(title)

    pub = dom.createElement("pubDate")
    pub.appendChild(dom.createTextNode(rfc822_now()))
    item.appendChild(pub)

    sv = dom.createElement("sparkle:shortVersionString")
    sv.appendChild(dom.createTextNode(args.short_version))
    item.appendChild(sv)

    ver = dom.createElement("sparkle:version")
    ver.appendChild(dom.createTextNode(args.build))
    item.appendChild(ver)

    if args.min_system_version:
        msv = dom.createElement("sparkle:minimumSystemVersion")
        msv.appendChild(dom.createTextNode(args.min_system_version))
        item.appendChild(msv)

    if args.notes_html:
        desc = dom.createElement("description")
        desc.appendChild(dom.createCDATASection(args.notes_html))
        item.appendChild(desc)

    enc = dom.createElement("enclosure")
    enc.setAttribute("url", args.enclosure_url)
    enc.setAttribute("length", length)
    enc.setAttribute("type", "application/octet-stream")
    enc.setAttribute("sparkle:edSignature", ed_signature)
    item.appendChild(enc)

    # Insert the new <item> as the first child of <channel>, right after
    # the channel's title/link/description block. We anchor on the first
    # existing <item> if any, otherwise append.
    existing_items = channel.getElementsByTagName("item")
    if existing_items:
        channel.insertBefore(item, existing_items[0])
    else:
        channel.appendChild(item)

    # Write back. minidom.toprettyxml introduces blank lines around
    # CDATA which Sparkle tolerates; we strip the worst offenders so
    # the file stays readable in `git diff`.
    pretty = dom.toprettyxml(indent="    ", encoding="utf-8").decode("utf-8")
    pretty = re.sub(r"\n\s*\n", "\n", pretty)
    args.appcast.write_text(pretty, encoding="utf-8")

    print(f"appcast updated: {args.appcast} (+ {args.short_version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
