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
