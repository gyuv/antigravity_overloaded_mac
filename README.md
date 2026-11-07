# Antigravity Code for macOS

A native macOS (Universal 2: Apple Silicon + Intel) autonomous coding agent: a SwiftUI desktop app plus the
`agcode` terminal companion. It reproduces the Claude Code workflow — repository indexing, file edits with
validated patches, PTY command execution, git operations, approval gating — on top of the Google
Antigravity / Gemini function-calling API (default model `gemini-3.1-pro-preview`).

## Layout

```
Package.swift                      SwiftPM manifest (macOS 12+)
Sources/AntigravityCore/           Engine shared by the GUI and the CLI
  Agent/AgentSession.swift         ReAct loop: stream → function calls → permission gate → execute → respond
  Agent/Permissions.swift          Review / Turbo / Auto modes + shell command risk classifier
  Agent/AuditLog.swift             JSONL audit trail (~/Library/Logs/AntigravityCode)
  LLM/GeminiClient.swift           SSE streaming client (streamGenerateContent?alt=sse), thought signatures preserved
  LLM/Credentials.swift            Keychain API key, env vars, Vertex AI OAuth via gcloud
  Tools/                           read_file, write_file, patch_file, list_dir, glob, grep, outline,
                                   execute_bash (openpty + posix_spawn, timeouts, process-group kill),
                                   git_action, update_plan
  Support/                         Workspace sandbox, unified diff engine, JSON value type
Sources/agcode/                    CLI companion (REPL, -p one-shot, y/a/n approvals, slash commands)
Sources/AntigravityCodeApp/        SwiftUI app: chat + thinking + tool cards | terminal / diff / plan inspector
Packaging/                         Info.plist, hardened-runtime entitlements
scripts/build-universal.sh         per-arch release builds → lipo → .app → codesign → .dmg → notarize
```

## Build

Requires Xcode 15+ (Swift 5.9) on macOS.

```bash
make test        # unit tests
make app         # dist/Antigravity Code.app  (arm64 + x86_64, ad-hoc signed)
make dmg         # dist/AntigravityCode-<version>-universal.dmg
```

Developer ID signing and notarization:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=agcode-notary make dmg
```

(`NOTARY_PROFILE` is created once with `xcrun notarytool store-credentials agcode-notary ...`.)

## Authentication

In priority order:
1. `ANTIGRAVITY_API_KEY`, `GEMINI_API_KEY` or `GOOGLE_API_KEY`
2. The macOS Keychain (`agcode login`, or Settings ⌘, in the app)
3. OAuth / Vertex AI: set `GOOGLE_CLOUD_PROJECT` (and optionally `GOOGLE_CLOUD_LOCATION`, default `global`)
   and sign in with `gcloud auth login`; a token is fetched with `gcloud auth print-access-token`.

## CLI

```bash
agcode                         # interactive session in the current repo
agcode -p "run the tests and fix failures" --turbo
agcode --mode review -m gemini-3.1-pro-preview
```

Install it from the app (Agent → Install ‘agcode’ Command Line Tool…) or with `make install-cli`, which symlinks
`Antigravity Code.app/Contents/Helpers/agcode` into `/usr/local/bin`.

## Permission modes

| Mode | Reads / search / plan | Build & test commands | File edits | Other shell / git writes | Destructive (`rm`, `git reset`, push, deploy…) |
|---|---|---|---|---|---|
| Review (default) | auto | auto | ask (with diff) | ask | ask |
| Turbo | auto | auto | auto (diff shown) | ask | ask |
| Auto-approve all | auto | auto | auto | auto | auto |

Every tool call, decision and result is appended to the audit log. Choosing "always" grants a tool for the rest
of the session, but never for destructive calls.

## Project memory

`ANTIGRAVITY.md`, `AGENTS.md` (and `CLAUDE.md`) at the repository root are injected into the system prompt.

## Status

The engine and UI are complete enough to run end-to-end; it was authored without a macOS machine, so the CI
workflow (`.github/workflows/build.yml`, macOS runner) is the first full compile of the universal build.
