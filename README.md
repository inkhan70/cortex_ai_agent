# Cortex AI Agent (v2)

Autonomous Flutter dev-agent app: background terminal execution, an offline
model/library hub, web-search-assisted auto-repair, and evolution analytics.

## What's here

| File | Purpose |
|---|---|
| `lib/services/terminal_runner_service.dart` | Non-interactive process execution engine (`Process.start`), streaming stdout/stderr, timeouts, cancellation. |
| `lib/services/cortex_loop_engine.dart` | Orchestrates Resolve Dependencies → Lint → Test → Build, with retry + auto-repair. |
| `lib/services/search_service.dart` | Tavily / Google CSE fallback search + error-signature detection. |
| `lib/services/offline_hub_service.dart` | Ollama/LM Studio/LocalAI connection manager + offline doc cache (sqflite). |
| `lib/screens/terminal_screen.dart` | Live log viewer, auto-scroll, clear, status chips. |
| `lib/screens/offline_hub_screen.dart` | Server auto-detect/manual connect UI + doc search. |
| `lib/screens/analytics_screen.dart` | `fl_chart` evolution graph + summary stats. |
| `lib/main.dart` | Material 3 app shell, bottom navigation, Provider wiring. |

## ⚠️ Read before you build: the mobile process-execution reality

`dart:io` `Process.run`/`Process.start` require a real OS shell with the
target toolchain (`flutter`, `npm`, etc.) on `PATH`. That exists on **desktop**
(Linux/macOS/Windows) and on a companion build-agent you run yourself. It does
**not** exist inside a stock iOS sandbox, and on stock Android there is no
`flutter`/`npm` binary installed inside your app's sandbox either — those
tools live on your dev machine, not on end-user phones.

So, practically:
- Run this app as a **Flutter Desktop** target against a real project
  checkout, **or**
- Point `CortexLoopEngine` at a small companion HTTP/WebSocket build-agent
  daemon running on your dev machine/CI box, and adapt
  `TerminalRunnerService` to call that daemon instead of `Process.start`
  directly, **or**
- Accept that on a distributed mobile APK, the "Autonomous Shell Execution"
  feature only makes sense talking to a LAN-reachable agent (this is exactly
  the same shape as the Offline Model Hub's LAN connection pattern).

`TerminalRunnerService.isProcessExecutionSupported` reflects this and the
service degrades gracefully (logs "unsupported platform") rather than
crashing when run somewhere without a real shell.

## Setup

```bash
flutter create --project-name cortex_ai_agent --org com.yourcompany --platforms android .  # if starting fresh
# or, drop these lib/, test/, pubspec.yaml files into an existing flutter project
flutter pub get
```

Add your search API key at runtime via the app's Settings flow (backed by
`SearchService.saveTavilyKey` / `saveGoogleCredentials`) — never hardcode keys.

## Run

```bash
flutter run -d <device-id>          # mobile/emulator (terminal feature limited, see above)
flutter run -d linux|macos|windows  # desktop (full terminal feature)
```

## One-tap cloud build (Codemagic)

`codemagic.yaml` is included at the project root. Once this repo is pushed to
GitHub and connected in Codemagic, it auto-detects this config — you don't
need to configure the workflow by hand in the UI. It:

1. `flutter pub get`
2. `flutter analyze` (non-blocking — won't fail the build on lint warnings)
3. `flutter test`
4. `flutter build apk --release` (unsigned — installable directly via
   "unknown sources" on your own device; sign it properly before
   distributing to others / the Play Store)
5. Uploads the resulting `.apk` as a downloadable build artifact

Runs on a Linux instance (cheaper/faster than macOS minutes, and this
project has no iOS target) with a 30-minute cap.

## Build APK

```bash
flutter analyze
flutter test
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk
```

I could not run this step for you in this conversation — this sandbox has no
Flutter/Android SDKs installed and no network access to download them (the
sandbox's network allowlist covers package registries like pypi/npm/GitHub,
not `storage.googleapis.com` where the Flutter SDK ships from), so
`flutter build apk` isn't runnable here. Run the commands above locally or in
a CI job (GitHub Actions with `subosito/flutter-action` is the standard
choice) to produce the real APK.

## Pushing to GitHub

I don't have write/push credentials for your GitHub account from this
session, so I can't push directly. Fastest path:

```bash
git init
git add .
git commit -m "Cortex AI Agent v2: autonomous terminal, offline hub, search repair, analytics"
git remote add origin <your-repo-url>
git push -u origin main
```
