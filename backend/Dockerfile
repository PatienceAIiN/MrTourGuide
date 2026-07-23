# MrTouride API backend — Google Cloud Run ready.
# Build:  docker build -t mrtouride-api backend/
# Local:  docker run -p 8080:8080 -e DATABASE_URL=... -e GROQ_API_KEY=... mrtouride-api
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/server.dart -o bin/server

FROM debian:bookworm-slim
# ffmpeg: poster-frame extraction + transcode/mux. redis-server: in-container
# cache + rate-limiter so this stays a SINGLE Render service (no separate KV).
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg redis-server ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/bin/server /app/bin/server
# NB: `dart compile exe` is self-contained; the debian base already provides
# glibc, so we must NOT copy /runtime (that is only for a scratch base and
# clashes with debian's /lib symlink on buildkit).
# OTA version manifest (read from _backendDir=/app) + the built landing site
# (served as static files at / when present).
COPY --from=build /app/app_version.json /app/app_version.json
COPY --from=build /app/web /app/web
COPY --from=build /app/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
WORKDIR /app
# Render/Cloud Run inject PORT; uploads dir is ephemeral — R2 is the durable store.
ENV PORT=8080
EXPOSE 8080
# entrypoint boots the in-container Redis, then the API server.
CMD ["/app/entrypoint.sh"]
