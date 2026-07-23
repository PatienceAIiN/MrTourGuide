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
# ffmpeg is used by the ML pipeline for poster-frame extraction.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/bin/server /app/bin/server
# NB: `dart compile exe` is self-contained; the debian base already provides
# glibc, so we must NOT copy /runtime (that is only for a scratch base and
# clashes with debian's /lib symlink on buildkit).
# OTA version manifest (read from _backendDir=/app) + the built landing site
# (served as static files at / when present).
COPY --from=build /app/app_version.json /app/app_version.json
COPY --from=build /app/web /app/web
WORKDIR /app
# Render/Cloud Run inject PORT; uploads dir is ephemeral — R2 is the durable store.
ENV PORT=8080
EXPOSE 8080
CMD ["/app/bin/server"]
