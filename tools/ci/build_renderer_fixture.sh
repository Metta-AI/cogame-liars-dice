#!/usr/bin/env bash
# Assembles the worst-case renderer fixture into a directory that
# tools/ci/viewer_smoke.mjs can serve with --bundle: index.html plus the REAL
# client/renderer.js, the real chrome.css and the real assets (the bands are
# measured in the face they are drawn in, so the font has to be the shipped
# one). See client/fixtures/worst_case.html for why the fixture exists.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /path/to/output/dir" >&2
  exit 1
fi
output_dir="$1"

# The renderer and the fixture each keep their own copy of the server's caps
# on the two model-authored strings (MaxSayLen / MaxNotesLen), because the
# bands are sized from them. Nothing else compares the copies: raising a cap
# in sim.nim alone would silently under-reserve the band, and this fixture
# would stay green because its strings are built from ITS copy rather than
# from the server's. So the copies are checked here, against the Nim
# constants, before the fixture is assembled from them.
assert_cap() {
  local nim_const="$1" js_const="$2" want got file
  want="$(sed -nE "s/^[[:space:]]*${nim_const}\* = ([0-9_]+)\$/\1/p" \
    "${repo_dir}/src/liars_dice/sim.nim" | tr -d '_')"
  if [[ -z "${want}" ]]; then
    echo "::error::cannot read ${nim_const} from src/liars_dice/sim.nim" >&2
    exit 1
  fi
  for file in client/renderer.js client/fixtures/worst_case.js; do
    got="$(sed -nE "s/^[[:space:]]*var ${js_const} = ([0-9]+);\$/\1/p" \
      "${repo_dir}/${file}")"
    if [[ "${got}" != "${want}" ]]; then
      echo "::error::${file} has ${js_const} = ${got:-<not found>} but" \
        "src/liars_dice/sim.nim has ${nim_const} = ${want}." >&2
      echo "::error::The speech/notes bands are sized from these caps; a" \
        "stale mirror under-reserves them silently." >&2
      exit 1
    fi
  done
  echo "cap ${nim_const} = ${want} agrees in renderer.js and worst_case.js"
}
assert_cap MaxSayLen MAX_SAY_LEN
assert_cap MaxNotesLen MAX_NOTES_LEN

rm -rf "${output_dir}"
mkdir -p "${output_dir}/assets"
cp "${repo_dir}/client/renderer.js" "${repo_dir}/client/chrome.css" \
  "${repo_dir}/client/fixtures/worst_case.js" "${output_dir}/"
cp "${repo_dir}/client/fixtures/worst_case.html" "${output_dir}/index.html"
for asset in soldier_red_front.png soldier_blue_front.png \
  soldier_green_front.png soldier_yellow_front.png \
  arena_floor.png font.ttf; do
  cp "${repo_dir}/data/${asset}" "${output_dir}/assets/"
done
# viewer_smoke.mjs --bundle insists on a replay file to mount; the fixture
# builds its own payload in the page and ignores ?replay=, so hand it the
# smallest valid stand-in.
printf '{"protocol":"liarsdice.fixture.v1"}\n' > "${output_dir}/fixture.json"

test -s "${output_dir}/index.html"
test -s "${output_dir}/renderer.js"
echo "liars-dice worst-case renderer fixture: ${output_dir}"
