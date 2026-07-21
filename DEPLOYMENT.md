# MrTouride — Cloud Deployment Guide

## Architecture (production)

| Piece | Where | Notes |
|---|---|---|
| API backend (Dart) | **Google Cloud Run** | container in `backend/Dockerfile` |
| Database | **Neon Postgres** (already live) | `DATABASE_URL` env (direct endpoint) |
| Media (videos/covers/thumbs) | **Cloudflare R2** | S3-compatible; swap point is `MediaStorage` in `backend/bin/server.dart` |
| Landing + Creator Portal | Cloudflare Pages / Cloud Run | `web/dist/*` static output |
| App | Android APK (OTA via backend) | `flutter build apk --release` |

## 1. Backend → Cloud Run

```bash
gcloud auth login && gcloud config set project <PROJECT_ID>
gcloud run deploy mrtouride-api \
  --source backend/ \
  --region asia-south1 \
  --allow-unauthenticated \
  --set-env-vars "DATABASE_URL=<neon-direct-url>,GROQ_API_KEY=<key>" \
  --memory 512Mi
```

Then point the clients at the Cloud Run URL:
- Flutter: `lib/services/api_base.dart` → `apiBase`
- Angular: `const API` in `web/projects/*/src/app/app.ts`

Note: the server binds `InternetAddress.loopbackIPv4` for local dev — change
to `InternetAddress.anyIPv4` and read `PORT` from env before deploying:
`shelf_io.serve(handler, InternetAddress.anyIPv4, int.parse(Platform.environment['PORT'] ?? '8080'))`.

## 2. Media → Cloudflare R2

1. Create an R2 bucket (`mrtouride-media`) + API token (Object Read & Write).
2. Implement `R2Storage implements MediaStorage` (same interface as
   `LocalFolderStorage`) using S3 PUT/GET against
   `https://<account_id>.r2.cloudflarestorage.com` with SigV4 —
   or simpler: front the bucket with an R2 public bucket / Worker and keep
   uploads via the Worker.
3. Swap in `main()`:
   `_storage = env has R2_* ? R2Storage(...) : LocalFolderStorage(...)`.
4. Env contract: `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
   `R2_BUCKET`, `R2_PUBLIC_BASE` (public URL prefix used in `/files` links).

Cloud Run's filesystem is ephemeral — R2 is required in production for
uploads to survive restarts.

## 3. Web apps → Cloudflare Pages

```bash
cd web && npx ng build landing && npx ng build creator-portal
npx wrangler pages deploy dist/landing/browser --project-name mrtouride
npx wrangler pages deploy dist/creator-portal/browser --project-name mrtouride-studio
```

## 4. Android release

```bash
flutter build apk --release            # or --split-per-abi
cp build/app/outputs/flutter-apk/app-release.apk backend/apk/mrtouride.apk
# bump backend/app_version.json → landing CTA + in-app OTA light up
```

## Secrets

Never commit `DATABASE_URL`, `GROQ_API_KEY`, or R2 keys. Use
`gcloud run services update --set-env-vars` / Secret Manager. The Groq key
currently used in dev should be **rotated** before going public (it was
shared in chat).
