# edupage-cli as a public MCP server (`edupage server --public`).
#
# Two stages: the first builds the gem and compiles native extensions, the second
# carries only the installed gems on a slim Ruby, without compilers or caches.

FROM ruby:4.0-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# sqlite3 is not a gem dependency (only public mode needs it), so it is installed here.
RUN gem build edupage-cli.gemspec \
 && gem install --no-document ./edupage-cli-*.gem sqlite3 \
 && rm -rf /usr/local/bundle/cache /usr/local/bundle/gems/*/ext /usr/local/bundle/gems/*/test \
           /usr/local/bundle/gems/*/spec


FROM ruby:4.0-slim

COPY --from=build /usr/local/bundle /usr/local/bundle

RUN useradd --system --uid 10001 --home-dir /data --shell /usr/sbin/nologin edupage \
 && mkdir -p /data \
 && chown edupage /data \
 && chmod 0700 /data

ENV EDUPAGE_DATA_DIR=/data \
    EDUPAGE_CONFIG=/data/config.yml \
    EDUPAGE_CACHE_DIR=/data/cache \
    HOME=/data

USER edupage
WORKDIR /data
VOLUME /data
EXPOSE 4567

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD ["ruby", "-rnet/http", "-e", "exit Net::HTTP.get_response(URI('http://127.0.0.1:4567/healthz')).is_a?(Net::HTTPSuccess)"]

CMD ["edupage", "server", "--public", "--host", "0.0.0.0"]
