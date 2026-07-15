# Builds a self-contained Cympho release (bundled ERTS) for glibc Linux.
#
# We build inside the pinned Debian-based Elixir image (matching the project's
# 1.19.5 / OTP 28 toolchain) rather than on the host, whose system Elixir is too
# old. Debian (glibc) — not Alpine (musl) — so the extracted release and the
# argon2 NIF run on the Ubuntu host. The release is then run natively under
# systemd; this image is only a throwaway build tool.
FROM elixir:1.19.5-otp-28 AS build

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
RUN mix tailwind.install --if-missing \
 && mix esbuild.install --if-missing \
 && mix tailwind cympho --minify \
 && mix esbuild cympho --minify \
 && mix phx.digest

RUN mix release --overwrite

# Minimal stage that only carries the built release out for `docker cp`.
FROM debian:bookworm-slim AS artifact
COPY --from=build /app/_build/prod/rel/cympho /rel
