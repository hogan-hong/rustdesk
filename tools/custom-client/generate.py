#!/usr/bin/env python3
"""Sign a custom-client JSON config into a RustDesk custom.txt.

custom.txt content = base64(ed25519_attached_signature(json) )  i.e. sig(64B) || json.
The matching public key is compiled into src/common.rs (read_custom_client KEY const).

Usage: python3 generate.py <config.json> <output-custom.txt>
Requires: pip install pynacl
"""
import base64
import json
import os
import sys
from pathlib import Path

from nacl.signing import SigningKey


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: generate.py <config.json> <output-custom.txt>")
        sys.exit(1)
    # The signing key is NOT kept in the repo (it would leak on a public repo).
    # Provide it via the CUSTOM_SIGNING_KEY env var (base64 of the 32-byte
    # ed25519 seed) or a path via CUSTOM_SIGNING_KEY_FILE.
    key_file = Path(os.environ.get(
        "CUSTOM_SIGNING_KEY_FILE",
        Path(__file__).parent / "signing-key.b64",
    ))
    raw = os.environ.get("CUSTOM_SIGNING_KEY")
    if raw:
        sk = SigningKey(base64.b64decode(raw.strip()))
    elif key_file.exists():
        sk = SigningKey(base64.b64decode(key_file.read_text().strip()))
    else:
        print("error: signing key not found; set CUSTOM_SIGNING_KEY "
              "or CUSTOM_SIGNING_KEY_FILE")
        sys.exit(1)
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    msg = json.dumps(data, separators=(",", ":")).encode("utf-8")
    signed = sk.sign(msg)  # attached signature: sig(64) || msg, same as libsodium crypto_sign
    out = base64.b64encode(signed).decode("ascii")
    Path(sys.argv[2]).write_text(out, encoding="ascii")
    print(f"wrote {sys.argv[2]} ({len(out)} chars)")


if __name__ == "__main__":
    main()
