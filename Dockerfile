FROM oven/bun:1.4.4@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d AS web
WORKDIR /source/app
COPY app/package.json app/bun.lock ./
RUN bun install --frozen-lockfile
COPY app/ ./
COPY assets/ /source/assets/
COPY server/priv/content/ /source/server/priv/content/
RUN bun run --bun build

FROM elixir:1.20.4-otp-29-slim@sha256:6245171c91cf90808437f203f22856738d0095d310f4f9030219e53111823ff8 AS beam
WORKDIR /source/server
ENV MIX_ENV=prod
COPY server/mix.exs server/mix.lock ./
RUN mix local.hex 2.5.1 --force && mix local.rebar --force && mix deps.get --check-locked
COPY server/config/ config/
RUN mix deps.compile
COPY server/lib/ lib/
COPY server/priv/ priv/
COPY --from=web /source/server/priv/static/ priv/static/
RUN mix compile --warnings-as-errors && mix release

FROM elixir:1.20.4-otp-29-slim@sha256:6245171c91cf90808437f203f22856738d0095d310f4f9030219e53111823ff8
WORKDIR /app
COPY --from=beam --chown=10001:10001 /source/server/_build/prod/rel/feud_hall/ ./
ENV HOME=/tmp
USER 10001:10001
EXPOSE 4000
CMD ["/app/bin/feud_hall", "start"]
