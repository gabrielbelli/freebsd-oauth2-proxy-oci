#!/usr/bin/env python3
"""
The two bits of pkg(8) knowledge this build needs, and nothing else.

Kept apart from fetch-pkg.sh so both are readable, and so the checksum format
can be tested on its own — it is the part that would fail silently if it were
wrong.
"""

import hashlib
import json
import sys

# pkg's own base32 alphabet (z-base-32), least significant bit first within
# each byte. Worked out against a real package rather than assumed: a checksum
# check that can never match is worse than no check, because it looks like one.
ALPHABET = "ybndrfg8ejkmcpqxot1uwisza345h769"


def zbase32(raw: bytes) -> str:
    out, acc, nbits = [], 0, 0
    for b in raw:
        acc |= b << nbits
        nbits += 8
        while nbits >= 5:
            out.append(ALPHABET[acc & 31])
            acc >>= 5
            nbits -= 5
    if nbits:
        out.append(ALPHABET[acc & 31])
    return "".join(out)


def find(index_path: str, want: str) -> None:
    """Print version, repopath and checksum for one package, or exit non-zero."""
    with open(index_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("name") != want:
                continue
            deps = sorted((entry.get("deps") or {}).keys())
            if deps:
                sys.exit(
                    f"{want} now declares dependencies {deps}. This build fetches a "
                    f"single package and does not resolve a dependency graph, so the "
                    f"image would be missing them. Resolve them explicitly or build "
                    f"on FreeBSD with pkg."
                )
            print(entry["version"])
            print(entry["repopath"])
            print(entry.get("sum", ""))
            return
    sys.exit(f"{want} is not in the index")


def verify(path: str, want: str) -> None:
    if not want:
        sys.exit("the index carried no checksum for this package")
    version, _, digest = want.partition("$")
    if version != "2":
        sys.exit(f"unsupported pkg checksum version {version!r}; refusing to skip the check")
    with open(path, "rb") as fh:
        got = zbase32(hashlib.blake2b(fh.read()).digest())
    if got != digest:
        sys.exit(f"checksum mismatch\n  expected {digest}\n  got      {got}")
    print("==> blake2b checksum ok")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "find":
        find(sys.argv[2], sys.argv[3])
    elif cmd == "verify":
        verify(sys.argv[2], sys.argv[3])
    else:
        sys.exit(f"unknown command {cmd!r}")
