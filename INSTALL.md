# Carbide2 Server — Installation Guide

## System Requirements

| Component | Version |
|-----------|---------|
| Ruby      | 3.4.x   |
| Bundler   | 2.x     |
| Node.js   | 18.x+   |
| npm       | 9.x+    |
| SQLite    | 3.8+    |
| OS        | Linux (inotify required for FS watching) |

---

## 1. Clone the repository

```bash
git clone --recurse-submodules https://github.com/fdimitri/carbide2-server.git
cd carbide2-server
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

---

## 2. Install Ruby (via RVM)

```bash
# Install RVM if not present
\curl -sSL https://get.rvm.io | bash -s stable
source ~/.rvm/scripts/rvm

# Install and use Ruby 3.4.2
rvm install 3.4.2
rvm use 3.4.2 --default
```

Alternatively use **rbenv**:

```bash
rbenv install 3.4.2
rbenv global 3.4.2
```

---

## 3. Install Ruby gems

```bash
gem install bundler
bundle install
```

---

## 4. Configure environment

Copy the example env file and fill in values:

```bash
cp .env.example .env
```

Minimum required values for local development:

```dotenv
# Database (defaults to storage/development.sqlite3 — can leave blank for default)
DATABASE_URL=sqlite3:storage/development.sqlite3

# Secret used to sign worker JWT tokens — any non-empty string works locally
WORKER_JWT_SECRET=changeme

# How long worker tokens stay valid (seconds)
WORKER_TOKEN_EXPIRY_SECONDS=600
```

OAuth keys (`OAUTH_GITHUB_*`, `OAUTH_GOOGLE_*`) are optional — omit them if you
don't need social login.

---

## 5. Set up the database

```bash
bundle exec rails db:setup      # creates DB, runs migrations, seeds dev user
```

This seeds a default developer account:

| Field    | Value           |
|----------|-----------------|
| Email    | dev@example.com |
| Password | password        |

And a default project: **Demo Project** (id: 1).

---

## 6. Install Node dependencies (Vue client)

```bash
cd clients/carbide2-client
npm install
cd ../..
```

---

## 7. (Optional) Import a project directory into the virtual filesystem

```bash
bundle exec rails runner "FsLoader.new(project_id: 1, root_path: '/path/to/your/project').load!"
```

Skip this step to start with an empty filesystem.

---

## 8. Start the development stack

```bash
./dev.sh
```

This launches three processes:

| Process      | Address                  | Log                          |
|--------------|--------------------------|------------------------------|
| Rails API    | http://localhost:3000    | stdout                       |
| Worker (WS)  | ws://localhost:8080      | /tmp/carbide2-worker.log     |
| Vite (Vue)   | http://localhost:5173    | stdout                       |

Stop everything with **Ctrl-C**.

---

## 9. Verify the install

Open http://localhost:5173, log in with `dev@example.com` / `password`, and open
the Demo Project. The file explorer should populate and files should be editable.

Worker logs:

```bash
tail -f /tmp/carbide2-worker.log
```

---

## Running tests

### Rails (unit/model tests)

```bash
bundle exec rails test
```

### Vue / Playwright end-to-end tests

Requires the full dev stack (`./dev.sh`) to be running first.

```bash
cd clients/carbide2-client

# All e2e tests
npm run test:e2e

# Smoke test (console + WS frames)
npm run test:smoke

# Individual specs
npx playwright test tests/e2e/editor.spec.js --reporter=list
npx playwright test tests/e2e/terminal.spec.js --reporter=list
npx playwright test tests/e2e/chat.spec.js --reporter=list
```

---

## Troubleshooting

**`bundle install` fails on `eventmachine`**  
Install the build tools: `sudo apt install build-essential libssl-dev`

**Worker won't start / JWT errors**  
Check that `WORKER_JWT_SECRET` is set in `.env` and matches what the Rails API
uses to sign tokens.

**Monaco editor shows "Loading…" indefinitely**  
The worker WS must be running on port 8080. Check `/tmp/carbide2-worker.log` for
connection errors.

**SQLite `database is locked`**  
The DB runs in WAL mode; ensure no stale Rails/worker processes are holding the
file open: `pkill -f 'rails server'; pkill -f 'worker.rb'`
