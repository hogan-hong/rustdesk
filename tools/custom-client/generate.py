#!/usr/bin/env python3
"""Sign a custom-client JSON config into a RustDesk custom.txt.

custom.txt content = base64(ed25519_attached_signature(json) )  i.e. sig(64B) || json.
The matching public key is compiled into src/common.rs (read_custom_client KEY const).

Usage: python3 generate.py <config.json> <output-custom.txt>
Requires: pip install pynacl
"""
import base64
import json
import sys
from pathlib import Path

from nacl.signing import SigningKey


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: generate.py <config.json> <output-custom.txt>")
        sys.exit(1)
    key_file = Path(__file__).parent / "signing-key.b64"
    sk = SigningKey(base64.b64decode(key_file.read_text().strip()))
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    msg = json.dumps(data, separators=(",", ":")).encode("utf-8")
    signed = sk.sign(msg)  # attached signature: sig(64) || msg, same as libsodium crypto_sign
    out = base64.b64encode(signed).decode("ascii")
    Path(sys.argv[2]).write_text(out, encoding="ascii")
    print(f"wrote {sys.argv[2]} ({len(out)} chars)")


if __name__ == "__main__":
    main()
