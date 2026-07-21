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
COPY --from=build /runtime/ /
WORKDIR /app
# Cloud Run injects PORT; uploads dir is ephemeral on Cloud Run — use R2 in prod.
ENV PORT=8080
EXPOSE 8080
CMD ["/app/bin/server"]
