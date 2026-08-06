#!/usr/bin/env bash
#
# Collect the full license text of every third-party component Parrot ships or
# depends on, into a single THIRD-PARTY-LICENSES.txt. Satisfies the attribution
# terms of the MIT / Apache 2.0 / ISC licenses in the stack. Run by `make app`
# to bundle the file into Parrot.app/Contents/Resources; also committed at the
# repo root for transparency.
#
# Usage: collect-licenses.sh <output-file>

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-THIRD-PARTY-LICENSES.txt}"
CHECKOUTS=".build/checkouts"

if [[ ! -d "$CHECKOUTS" ]]; then
    echo "ERROR: $CHECKOUTS not found — run 'swift build' first." >&2
    exit 1
fi

section() {
    printf '\n\n============================================================\n' >>"$OUT"
    printf '%s\n' "$1" >>"$OUT"
    printf '============================================================\n\n' >>"$OUT"
}

cat >"$OUT" <<'HEADER'
Parrot — Third-Party Licenses
=============================

Parrot bundles or depends on the open-source components below. Each is used
under its own license, reproduced in full. Parrot itself is MIT licensed (see
the LICENSE file).
HEADER

# --- SwiftPM dependencies (every resolved package with a license file) -------
for dir in "$CHECKOUTS"/*/; do
    name="$(basename "$dir")"
    lic="$(find "$dir" -maxdepth 1 -iname 'license*' 2>/dev/null | head -1)"
    [[ -n "$lic" ]] || continue
    section "$name"
    cat "$lic" >>"$OUT"
done

# --- Components not fetched via SwiftPM --------------------------------------

# Lucide icons (the bird glyph used for the app icon). ISC licensed.
section "Lucide (app icon glyph) — https://lucide.dev"
cat >>"$OUT" <<'ISC'
ISC License

Copyright (c) 2020, Lucide Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
ISC

# OpenAI Whisper models (downloaded on demand at runtime, not bundled). MIT.
section "OpenAI Whisper models (downloaded at runtime) — https://github.com/openai/whisper"
cat >>"$OUT" <<'WHISPER'
MIT License

Copyright (c) 2022 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
WHISPER

count=$(grep -c '^====' "$OUT" || true)
echo "    Wrote $OUT ($(( count / 2 )) components)"
