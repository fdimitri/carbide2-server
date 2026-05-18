# Carbide2 IDE — Vue 3 Frontend

A modern Vue 3 + Vite SPA frontend for the Carbide2 IDE collaborative development environment.

## Features

- **Login/Authentication** — Local Devise auth via Rails API
- **Dashboard** — Welcome page with quick-access cards
- **API Integration** — Test API connectivity from the dashboard
- **Responsive Design** — Works on desktop and tablet
- **Token-based Auth** — Bearer token stored in localStorage

## Setup

### Prerequisites

- Node.js 16+ and npm (or yarn/pnpm)
- Rails backend running on `http://localhost:3000`

### Installation

```bash
cd frontend
npm install
```

### Development

Run the Vue dev server on port 5173 with API proxy:

```bash
npm run dev
```

Then open [http://localhost:5173](http://localhost:5173) in your browser.

**Login credentials (demo):**
- Email: `dev@example.com`
- Password: `password`

### Build for Production

```bash
npm run build
```

Output will be in `frontend/dist/`.

## Project Structure

```
frontend/
├── index.html              # Entry HTML
├── src/
│   ├── main.js             # Vue app bootstrap
│   ├── App.vue             # Root component with navbar
│   ├── pages/
│   │   ├── LoginPage.vue   # Login form
│   │   └── DashboardPage.vue # Authenticated dashboard
│   ├── services/
│   │   └── authService.js  # Auth + API client
│   └── router/
│       └── index.js        # Vue Router setup
├── vite.config.js          # Vite config with API proxy
└── package.json
```

## API Integration

The frontend communicates with the Rails API at `http://localhost:3000/api`.

### Auth Flow

1. User enters credentials on login page
2. Frontend POSTs to `POST /api/users/sign_in`
3. Backend returns user + token
4. Frontend stores token in localStorage and sets `Authorization: Bearer <token>` header
5. Subsequent requests include the token

### Running Frontend + Backend Together

**Terminal 1 — Rails API:**
```bash
cd /path/to/carbide2-server
bundle exec rails server -p 3000
```

**Terminal 2 — Vue Frontend:**
```bash
cd /path/to/carbide2-server/frontend
npm run dev
```

Then open [http://localhost:5173](http://localhost:5173).

## Next Steps

- Add projects listing and creation
- Integrate terminal WebSocket connection
- Display file tree from backend
- Build editor UI

## Notes

- The auth service stores the token in localStorage for persistence across page reloads
- The Vite dev server proxies `/api` requests to the Rails backend (see `vite.config.js`)
- CORS is handled by Rails (check `config/initializers/cors.rb`)
