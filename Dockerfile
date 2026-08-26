# Liar's Dice game + player image. One image, two entrypoints:
#   /bin/liars-dice         - the game server (default)
#   /bin/liars-dice-player  - the prompt-delivery player
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/liars-dice
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# The repo nim.cfg pins the host machine's package paths; regenerate it from
# the container's synced package tree.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/liars-dice-nimcache --out:liars-dice src/liars_dice.nim && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/liars-dice-player-nimcache --out:liars-dice-player \
    src/liars_dice_player.nim

# Run image.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/liars-dice
COPY --from=build /workspace/liars-dice/liars-dice /bin/liars-dice
COPY --from=build /workspace/liars-dice/liars-dice-player /bin/liars-dice-player
COPY --from=build /workspace/liars-dice/data ./data
COPY --from=build /workspace/liars-dice/client ./client

CMD ["/bin/liars-dice"]
