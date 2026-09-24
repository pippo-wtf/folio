#!/usr/bin/env python3
"""Check a disposable signed feed and reject tampered copies without launching Folio."""
import argparse
from pathlib import Path
import subprocess
import tempfile
from typing import Optional
from urllib.parse import urlparse
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument("fixture", type=Path, help="/private/tmp/folio-update-test.* directory")
args = parser.parse_args()
root = args.fixture.resolve()
if not str(root).startswith("/private/tmp/folio-update-test."):
    parser.error("fixture must be a disposable /private/tmp/folio-update-test.* directory")
feed_dir = root / "feed"
feed = feed_dir / "appcast.xml"
tool = Path(__file__).resolve().parent.parent / ".build/test/artifacts/sparkle/Sparkle/bin/sign_update"
if not tool.is_file():
    parser.error(f"Sparkle sign_update tool is missing: {tool}")
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
item = ET.parse(feed).getroot().find(".//item")
if item is None:
    parser.error("no appcast item")
enclosure = item.find("enclosure")
notes_element = item.find(namespace + "releaseNotesLink")
if enclosure is None or notes_element is None:
    parser.error("archive or release notes missing")

def local_file(url: str) -> Path:
    parsed = urlparse(url)
    if parsed.scheme != "http" or parsed.hostname != "127.0.0.1":
        parser.error("fixture URL is not loopback HTTP")
    path = feed_dir / Path(parsed.path).name
    if not path.is_file():
        parser.error(f"fixture file is missing: {path}")
    return path

archive = local_file(enclosure.attrib["url"])
notes = local_file(notes_element.text or "")
archive_signature = enclosure.attrib[namespace + "edSignature"]
notes_signature = notes_element.attrib[namespace + "edSignature"]

def accepts(path: Path, signature: Optional[str] = None) -> bool:
    command = [str(tool), "--account", "wtf.pippo.folio.staging", "--verify", str(path)]
    if signature:
        command.append(signature)
    return subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

for path, signature in ((feed, None), (archive, archive_signature), (notes, notes_signature)):
    if not accepts(path, signature):
        raise SystemExit(f"valid signature rejected: {path.name}")
with tempfile.TemporaryDirectory(prefix="folio-signature-probe.", dir="/private/tmp") as temporary:
    temporary = Path(temporary)
    bad_feed = temporary / "appcast.xml"
    original = feed.read_bytes()
    title = item.find("title")
    if title is None or not title.text:
        raise SystemExit("test feed title not found")
    title_tag = ("<title>" + title.text + "</title>").encode()
    changed_tag = ("<title>" + title.text + " tampered</title>").encode()
    tampered = original.replace(title_tag, changed_tag, 1)
    if tampered == original:
        raise SystemExit("test feed title could not be changed")
    bad_feed.write_bytes(tampered)
    bad_archive = temporary / archive.name
    changed = bytearray(archive.read_bytes())
    changed[-100] ^= 1
    bad_archive.write_bytes(changed)
    bad_notes = temporary / notes.name
    bad_notes.write_bytes(notes.read_bytes() + b"changed\n")
    for path, signature in ((bad_feed, None), (bad_archive, archive_signature), (bad_notes, notes_signature)):
        if accepts(path, signature):
            raise SystemExit(f"tampered copy was accepted: {path.name}")
print("3 original signatures accepted; 3 tampered copies rejected")
