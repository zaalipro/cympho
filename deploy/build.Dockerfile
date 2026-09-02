# Builds a self-contained Cympho release (bundled ERTS) for glibc Linux.
#
# We build inside a pinned Debian-based Elixir image (matching the project's
# 1.19.5 / OTP 28 toolchain) rather than on the host, whose system Elixir is too
# old. The base MUST be Debian bookworm: the deploy host is Debian 12
# (glibc 2.36), and an ERTS built against a newer glibc (e.g. the official
# elixir:* images, now on trixie) fails at runtime with `GLIBC_2.38 not found`.
# The release is run natively under systemd; this image is only a throwaway
# build tool.
FROM hexpm/elixir:1.19.5-erlang-28.4.3-debian-bookworm-20260713 AS build

ARG CYMPHO_BUILD_REVISION

# hexpm images are minimal: the argon2 NIF needs a C toolchain, heroicons needs git.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Fetch deps first for layer caching (git is needed for the heroicons dep).
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Compile-time config must be present before compiling deps.
COPY config config
RUN mix deps.compile

# Assets (esbuild/tailwind standalone binaries; tailwind scans lib/**/*.heex).
COPY priv priv
COPY assets assets
COPY lib lib
COPY bin bin
ENV CYMPHO_BUILD_REVISION=${CYMPHO_BUILD_REVISION}
RUN printf '%s' "$CYMPHO_BUILD_REVISION" | grep -Eq '^[0-9a-fA-F]{7,64}$' \
 && mix tailwind.install --if-missing \
 && mix esbuild.install --if-missing \
 && mix tailwind cympho --minify \
 && mix esbuild cympho --minify \
 && mix phx.digest

RUN mix release --overwrite \
 && release_root="/app/_build/prod/rel/cympho" \
 && app_version="$(awk -F'"' '/version: "/ { print $2; exit }' mix.exs)" \
 && test -n "$app_version" \
 && install -m 0755 bin/cymphoctl "$release_root/bin/cymphoctl" \
 && install -m 0755 bin/cympho-health-validator "$release_root/bin/cympho-health-validator" \
 && printf '{"schema_version":1,"service":"cympho","release":{"version":"%s","revision":"%s"}}\n' \
      "$app_version" "$CYMPHO_BUILD_REVISION" > "$release_root/release-info.json"

# Minimal stage that only carries the built release out for `docker cp`.
FROM debian:bookworm-slim AS artifact
COPY --from=build /app/_build/prod/rel/cympho /rel
