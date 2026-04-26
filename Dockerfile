FROM elixir:1.19.5-otp-28-alpine

WORKDIR /app

# Copy mix files first for caching
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix deps.get

COPY priv priv
COPY lib lib
COPY config config

# Build the release
RUN mix release

# Final image
FROM alpine:3.21
RUN apk add --no-cache bash openssl
WORKDIR /app
COPY --from=0 /app/_build/prod/rel/cympho .
ENV PORT=4000
EXPOSE 4000
CMD ["bin/cympho", "start"]
