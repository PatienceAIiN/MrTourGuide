# ✦ Mr.Tour Guide — *A product of [PatienceAI](https://patienceai.in)*

**Travel with your senses. From home.**

Immersive city experiences with video, MR/VR and real-feel haptics — built
for everyone the world is hard to reach for: people with disabilities, the
elderly, students, and anyone facing barriers.

**Live:** [mrtourguide.patienceai.in](https://mrtourguide.patienceai.in) ·
Creator Portal: [/studio](https://mrtourguide.patienceai.in/studio/)

---

## What it does

- **Travelers** browse cities (Jaipur, Agra, Amritsar, New Delhi …), play
  experience videos with **haptics + sound controls**, live weather per
  place, AI search with web knowledge, MR/VR mode, and a community feed.
- **Creators** (same login, app + web portal) upload videos and city covers,
  tune each video's **feel / sound / intensity**, preview exactly what
  travelers see, and post in a creators-only community.
- An **ML pipeline** (simulated today, real contract in place) trims and
  enhances every upload, extracts a poster frame (ffmpeg) and generates a
  per-video **haptic track** from its audio/motion.

## Architecture

| Piece | Tech | Where |
|---|---|---|
| App (Android + web) | Flutter, Material 3 expressive | `lib/` |
| API backend | Dart (shelf), compiled to a single binary | `backend/` |
| Landing page | Angular 20 | `../web/projects/landing` |
| Creator Portal | Angular 20 | `../web/projects/creator-portal` |
| Database | Neon Postgres (cloud) — local Postgres fallback | `DATABASE_URL` |
| Media storage | **Cloudflare R2** (S3 SigV4) with local write-through cache | `R2_*` env |
| AI search | Groq `compound-mini` (built-in web search), server-side key | `GROQ_API_KEY` |
| Prod hosting | GCE VM + nginx (TLS via Cloudflare origin cert) | `/opt/mrtouride` |

## Features

Auth (email verification + Google SSO rules) · role-gated communities with
replies, reactions and compressed image uploads · per-video experience
config · OTA update detection with APK distribution · live weather
(Open-Meteo) · ML cross-city suggestions · YouTube + photo search
suggestions · graded UI haptics ("guitar-string" feedback) · dark theme ·
accessibility (reduce motion, user settings always win) · per-IP API rate
limiting · DPDP consent + Terms/Privacy.

## Develop

```bash
# backend (reads backend/.env — see .env.example)
backend/run.sh

# app in Chrome
flutter run -d chrome --web-port 5000

# web apps
cd ../web && npx ng build landing && npx ng build creator-portal
node servers/serve.js dist/landing/browser 3002 landing
node servers/serve.js dist/creator-portal/browser 3001 studio
```

## Release

```bash
# APK (build LOCALLY, never on the server)
flutter build apk --release \
  --dart-define=API_BASE=https://mrtourguide.patienceai.in/api

# backend binary for the VM
cd backend && dart compile exe bin/server.dart -o server
```

See `DEPLOYMENT.md` for the full VM / Cloud Run / R2 guide.

## Environment variables

`DATABASE_URL` · `GROQ_API_KEY` · `R2_ENDPOINT` · `R2_BUCKET` ·
`R2_ACCESS_KEY_ID` · `R2_SECRET_ACCESS_KEY` — never commit these
(`backend/.env` is gitignored).

---

Built by **Team Trikers** · Mr.Tour Guide is a product of
**[PatienceAI](https://patienceai.in)** · contact@patienceai.in
