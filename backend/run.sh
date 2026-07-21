#!/usr/bin/env bash
# Starts the MrTouride backend with secrets from .env
cd "$(dirname "$0")"
set -a; source .env; set +a
exec /home/harsh/sdk/flutter/bin/dart run bin/server.dart
