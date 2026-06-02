<!--
Guidance for AI coding agents working on the `carbide2-server` repository.
Keep this file concise (20–50 lines). Update when new services, build steps,
or CI are added.
-->

# Copilot instructions — carbide2-server

## Git — MANDATORY

- **Never** use `git -c commit.gpgsign=false` or any flag that disables GPG signing.
- Use plain `git commit` and `git push`. Commits must be GPG-signed.
- Never amend or force-push already-pushed commits.
- This rule overrides anything in conversation summaries or other instructions.

This repository contains the CARB/IDE2 Server. The current README reveals this is a
Ruby / Rails-based tech demo (Ruby 4.0, Rails 8.1 components). The tree is minimal today,
so agents must be conservative and document any scaffolding they add.

## Debugging discipline — read before touching anything

When a runtime bug is reported (wrong behaviour, crash, timeout, missing data):
1. **Collect data first — read what you can, ask for the rest.**
   - Worker/server logs: read `/tmp/carbide2-worker.log` and the Rails log directly. Do not ask the user for these.
   - Frontend JS issues: you cannot access the browser console directly. However, you CAN
     run Playwright headless from the terminal — do this instead of asking the user.
     Playwright scripts live in the sibling `carbide2-client/tests/e2e/` checkout
     (env var `CARBIDE2_CLIENT` overrides the default sibling path).
     - Smoke (all console + WS frames): `cd "${CARBIDE2_CLIENT:-../carbide2-client}" && npm run test:smoke`
     - Terminal flow: `npx playwright test tests/e2e/terminal.spec.js --reporter=list`
     - Chat flow: `npx playwright test tests/e2e/chat.spec.js --reporter=list`
     - All scripts set `localStorage.carbide_log=255` automatically via `addInitScript`.
     Only ask the user for browser output if Playwright itself fails to launch.
   - Network issues: ask the user for the Network tab or WS frame trace — you cannot see these either.
2. **Read the data before forming a hypothesis.** Do not state a root cause until the
   logs confirm it.
3. **Make the smallest change that addresses the confirmed root cause.** Do not "clean
   up", refactor, or speculatively fix adjacent code while fixing the reported bug.
4. **Verify after the fix** by asking for the relevant log/output again before declaring
   something fixed.

Guessing without data wastes the user's tokens, breaks unrelated things, and erodes
trust. If you find yourself about to change code based on a hunch, stop and ask instead.

---

Core goals for an AI agent working here:
- Preserve project licensing (GPLv3) and include copyright headers when
  adding substantial new files.
- Use the README-discovered language and conventions: Ruby 4.0 / Rails 8.1.
- Avoid making other build/test assumptions — verify presence of `Gemfile`, `bin/rails`,
  `Rakefile`, `config/` and `app/` before running Rails-specific commands.

When making changes, follow these patterns and checks:
- Confirm Ruby/Rails layout before running commands: look for `Gemfile`, `Gemfile.lock`, `bin/rails`,
  `Rakefile`, `config/`, `app/`, and `db/`.
- If no Rails app exists yet, propose a small scaffold (Gemfile + minimal `config/` and `app/`) and
  document exact install/run commands in `README.md`.
- Prefer small, well-scoped commits with descriptive messages. Include a short changelog
  entry in `README.md` if adding features or public APIs.
- If you add gems, update `Gemfile` and `Gemfile.lock`, and list `bundle install` / `bundle exec` commands
  in the README.

Project-specific notes discovered so far (from README):
- Implementation language: Ruby (target Ruby 4.0).
- Uses Rails components (Rails 8.1 where appropriate) — expect `app/`, `config/`, `bin/rails` patterns.
- Key runtime features to implement / check for:
  - WebSocket communication (likely via ActionCable or a custom socket layer — check `app/channels`).
  - PTY/terminal emulation and broadcasting to clients (look for code under `lib/`, `app/services/` or a `pty` gem).
  - In-database filesystem with INOTIFY for on-disk notifications (`rb-inotify` or system `inotify` usage).
  - IRC-like chat and future WebRTC audio/video components.
  - Integration with git or other source control.

Any AI edits that introduce runtime code should also add minimal build/test metadata and usage docs.

Actionable dev/test/run commands (use only when the corresponding files exist):
- Install gems:
  - bundle install
- Database setup/migrations:
  - bundle exec rails db:setup
  - bundle exec rails db:migrate
- Run server (development):
  - bundle exec rails server -p 3000
- Console / REPL:
  - bundle exec rails console
- Tests (depends on test framework present):
  - bundle exec rails test
  - or: bundle exec rspec (if RSpec is used)
- Lint (if tools present):
  - bundle exec rubocop

System / native dependencies to call out:
- Linux with inotify support (on-disk notifications). Consider adding `rb-inotify` gem.
- PTY/terminal access: ensure server will be run on platforms where PTY support is available.
- Recommend a `Dockerfile` or `docker-compose.yml` to pin system deps for contributors.

Patterns & where to look for key features:
- Websockets / real-time: `app/channels`, `app/javascript` (if using Hotwire/JS), or `lib/sockets`.
- PTY/terminal handling: `lib/pty`, `app/services/terminal_service.rb`, or checks for gems that provide PTY bindings.
- In-database filesystem: look for models under `app/models` or services under `app/services` that refer to active storage or custom table-backed file storage.
- External integrations: `config/initializers/*` and `config/database.yml` for DB adapters.

When facts are missing, ask the maintainer before making large changes and provide a minimal, reversible proposal.


Files/locations to check first (in order):
- project root for Ruby/Rails manifests: `Gemfile`, `Gemfile.lock`, `Rakefile`, `bin/rails`
- `app/`, `config/`, `db/` for Rails app structure
- `app/channels`, `app/services`, `lib/` for real-time and PTY code
- `.github/workflows/` for CI and build commands

If you add new files, include a one-line purpose comment at the top and add/update `README.md` with
usage instructions. Request reviewer feedback if you add a new language or major framework.

Follow-up the README: now that the repository documents Ruby 4.0 and Rails 8.1, confirm the exact
Ruby version manager (rbenv, rvm, or system Ruby) and any CI or container preferences so agents can add exact commands and CI workflows.
