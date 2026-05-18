# Carbide2 IDE Server

A collaborative development environment with browser-based terminal emulation, built with Ruby on Rails and Vue 3.

## Architecture

- **Backend:** Rails 8.1 API server (REST + WebSocket)
- **Frontend:** Vue 3 + Vite SPA
- **Authentication:** Devise (local email/password)
- **Terminal:** EventMachine worker + PTY spawning
- **Database:** SQLite3 (development)

## Prerequisites

- **Ruby:** 3.4+ (uses RVM or rbenv)
- **Node.js:** 16+ (for frontend)
- **SQLite3:** Usually included with system

## Quick Start

### 1. Backend Setup

```bash
# Install gems
bundle install

# Set up database (creates tables, seeds dev user)
bundle exec rails db:setup

# Run server (port 3000)
bundle exec rails server -p 3000
```

**Demo login:**
- Email: `dev@example.com`
- Password: `password`

### 2. Frontend Setup

```bash
cd frontend

# Install dependencies
npm install

# Run dev server (port 5173 with API proxy)
npm run dev
```

Open [http://localhost:5173](http://localhost:5173) in your browser.

### 3. Worker (Optional)

To run the EventMachine PTY worker (requires separate setup):

```bash
ruby worker/worker.rb
```

Expects `WORKER_JWT_SECRET` env var and listens on `ws://localhost:8080` by default.

## Project Structure

```
carbide2-server/
├── app/
│   ├── controllers/     # API endpoints
│   ├── models/          # User, Project, TerminalSession
│   └── services/        # WorkerTokenIssuer
├── config/
│   ├── application.rb   # Rails config (API-only mode)
│   ├── routes.rb        # /api/projects/:project_id/terminals
│   └── initializers/    # Devise, CORS, OmniAuth (disabled)
├── db/
│   ├── migrate/         # Schema migrations
│   └── seeds.rb         # Demo user seed
├── frontend/            # Vue 3 + Vite (see frontend/README.md)
├── worker/              # EventMachine PTY server
├── Gemfile              # Ruby dependencies
└── .env.example         # Environment template

## Configuration

Copy `.env.example` to `.env` and configure:

```bash
cp .env.example .env
```

Key vars:
- `DEVISE_SECRET_KEY` — Devise secret (auto-generated)
- `WORKER_JWT_SECRET` — Secret for worker JWT signing
- `CORS_ORIGINS` — Allowed frontend origins (e.g., `http://localhost:5173`)

## API Endpoints

### Authentication
- `POST /users/sign_in` — Local login (Devise)
- `POST /users/sign_out` — Logout
- `POST /users` — Sign up

### Terminals
- `POST /api/projects/:project_id/terminals` — Create terminal session, returns JWT token

### Projects
- `GET /api/projects` — List projects (TODO)
- `POST /api/projects` — Create project (TODO)

## Development

### Database

Reset database:
```bash
bundle exec rails db:reset
```

Run migrations:
```bash
bundle exec rails db:migrate
```

### Testing

Rails tests (when available):
```bash
bundle exec rails test
```

Linting:
```bash
bundle exec rubocop
```

### Debugging

Rails console:
```bash
bundle exec rails console
```

## Deployment

### Docker

A `Dockerfile` is included for containerization:

```bash
docker build -t carbide2 .
docker run -p 3000:3000 carbide2
```

### Production Checklist

- [ ] Set `Rails.env = 'production'`
- [ ] Configure `SECRET_KEY_BASE`, `DATABASE_URL`
- [ ] Build frontend: `cd frontend && npm run build`
- [ ] Serve static files from Rails or CDN
- [ ] Use RS256 for JWT instead of HS256
- [ ] Enable HTTPS
- [ ] Configure real database (PostgreSQL)
- [ ] Set up background job queue (Solid Queue)

## Disabling OmniAuth (Current State)

OAuth (GitHub/Google) is currently disabled. To re-enable:

1. Add `:omniauthable` to User model (`app/models/user.rb`)
2. Uncomment `config/initializers/omniauth.rb`
3. Restore OmniAuth provider gems in `Gemfile`
4. Add session middleware in `config/application.rb`
5. Restore `Users::OmniauthCallbacksController`

See `.github/SCAFFOLD_NOTES.md` for details.

## Next Steps

- [ ] Implement FileTree API endpoint
- [ ] Connect Vue frontend to file tree
- [ ] Integrate EventMachine worker
- [ ] Build WebSocket terminal UI in Vue
- [ ] Add project CRUD endpoints
- [ ] Implement real-time collaboration features

## References

- [Rails 8.1 Guides](https://guides.rubyonrails.org/)
- [Vue 3 Docs](https://vuejs.org/)
- [Devise](https://github.com/heartcombo/devise)
- [EventMachine](https://github.com/eventmachine/eventmachine)

## License

GPLv3 (see LICENSE file)
