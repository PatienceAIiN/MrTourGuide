#!/bin/sh
# Single-service startup: run an in-container Redis (cache + rate-limit) next to
# the API. Redis is memory-only (no persistence) and LRU-capped so it never
# threatens the container's RAM. If it dies, the Dart server falls back to its
# in-memory limiter and simply skips the cache — the API keeps serving.
set -e
redis-server \
  --daemonize yes \
  --bind 127.0.0.1 \
  --port 6379 \
  --save "" \
  --appendonly no \
  --maxmemory 96mb \
  --maxmemory-policy allkeys-lru \
  --loglevel warning
exec /app/bin/server
