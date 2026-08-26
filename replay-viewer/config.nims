import std/[os, strformat, strutils]

let rootDir = currentSourcePath().parentDir().parentDir()
let distDir = rootDir / "replay-viewer" / "dist"

if not dirExists(distDir):
  mkDir(distDir)

switch("path", rootDir / "src")
switch("nimcache", distDir / "nimcache")
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--clang.cpp.exe:emcc
--clang.cpp.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:release
# Route allocations through emscripten's malloc; with Nim's own allocator a
# bad free silently poisons the freelists, dlmalloc traps loudly instead.
--define:useMalloc

# ABORTING_MALLOC: with -d:useMalloc Nim never checks malloc for nil, and
# wasm32 has no memory protection, so a failed allocation would write through
# the nil pointer into address 0 and corrupt the module's globals.
#
# MODULARIZE + EXPORT_NAME and the JS bootstrap are a MATCHED PAIR:
# static_replay.js calls the factory LiarsDiceReplayModule(). Swapping one for
# an onRuntimeInitialized bootstrap throws nothing, logs nothing and hangs the
# viewer forever (cogame-lantern, 2026-08-23).
switch(
  "passL",
  (&"""
  -o {distDir / "liars_dice_replay.js"}
  -O2
  -s ALLOW_MEMORY_GROWTH
  -s ABORTING_MALLOC=1
  -s ENVIRONMENT=web
  -s MODULARIZE=1
  -s EXPORT_NAME=LiarsDiceReplayModule
  -s EXPORTED_RUNTIME_METHODS=HEAPU8
  -s EXPORTED_FUNCTIONS=_main,_malloc,_free,_ld_load_replay,_ld_payload_ptr,_ld_payload_len,_ld_error_ptr,_ld_error_len
  """).replace("\n", " ")
)
