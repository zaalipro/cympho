FROM elixir:1.19.5-otp-28-alpine

WORKDIR /app
ENV MIX_ENV=prod
ARG CYMPHO_BUILD_REVISION
ENV CYMPHO_BUILD_REVISION=$CYMPHO_BUILD_REVISION

# Argon2 needs a C toolchain and the pinned Heroicons dependency needs git.
RUN apk add --no-cache build-base git
RUN mix local.hex --force && mix local.rebar --force

# Copy mix files first for caching
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config config
RUN mix deps.compile

COPY priv priv
COPY assets assets
COPY lib lib
COPY bin bin

# Build production assets before the release. Production endpoint compilation
# requires the generated cache manifest.
RUN printf '%s' "$CYMPHO_BUILD_REVISION" | grep -Eq '^[0-9a-fA-F]{7,64}$' \
 && mix tailwind.install --if-missing \
 && mix esbuild.install --if-missing \
 && mix tailwind cympho --minify \
 && mix esbuild cympho --minify \
 && mix phx.digest \
 && mix release \
 && release_root="/app/_build/prod/rel/cympho" \
 && app_version="$(awk -F'"' '/version: "/ { print $2; exit }' mix.exs)" \
 && test -n "$app_version" \
 && install -m 0755 bin/cymphoctl "$release_root/bin/cymphoctl" \
 && install -m 0755 bin/cympho-health-validator "$release_root/bin/cympho-health-validator" \
 && printf '{"schema_version":1,"service":"cympho","release":{"version":"%s","revision":"%s"}}\n' \
      "$app_version" "$CYMPHO_BUILD_REVISION" > "$release_root/release-info.json"

# Final image
FROM alpine:3.21
RUN apk add --no-cache bash ca-certificates curl libgcc libstdc++ ncurses-libs openssl python3 tini
WORKDIR /app
COPY --from=0 /app/_build/prod/rel/cympho .
ENV PORT=4000
ENV HTTP_BIND_IP=0.0.0.0
EXPOSE 4000
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["bin/cympho", "start"]
