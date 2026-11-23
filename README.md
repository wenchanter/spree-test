# my-store

A [Spree Commerce](https://spreecommerce.org) project.

## Getting Started

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed and running

### Start the Spree API

```bash
cd my-store
npx spree dev
```

The first run completes setup automatically — it pulls the latest Spree image,
seeds the database, and configures API keys.

Wait for the services to be healthy, then open:

- **Admin Dashboard:** http://localhost:5173 — started automatically by `spree dev`
  - The first run opens a setup link where you create the admin account
- **Seller Panel (marketplace):** http://localhost:5174 — run it with `cd apps/seller-dashboard && npm run dev`
- **Store API:** http://localhost:3001/api/v3/store

### Start the storefront

Dependencies are already installed during setup — just start it:

```bash
cd apps/storefront
npm run dev
```

Open http://localhost:3001

### The Admin Dashboard

`apps/dashboard/` is your admin — a customizable React SPA (plugins, your
own pages, table tweaks) with live reload. `spree dev` starts it
automatically alongside the API; to run it on its own:

```bash
cd apps/dashboard
npm run dev
```

Open http://localhost:5173 and sign in with the admin email and
password you chose during the first run.

When you deploy, the production image builds your dashboard and serves it at
`/dashboard` on the same origin as the API (`npx spree build --production`).

To learn how to add pages, tweak tables, or build plugins, see the
[Admin Dashboard docs](https://spreecommerce.org/docs/developer/dashboard/overview).

## Future Career authentication

The `future_career` Store authentication strategy is implemented in
`server/app/models/future_career/authentication_strategy.rb` and registered by
`server/config/initializers/future_career_authentication.rb`.
It verifies a 60-second RS256 assertion from Nuxt, checks the existing Customer ID,
email and login eligibility, and returns that Customer to Spree's native JWT issuer.
Customer creation and Magic Link / Google verification stay in Nuxt.
The initializer also enforces a minimum of 10 characters for new passwords, matching
Future Career recovery; a stricter configured minimum is preserved. Existing passwords
can still be used to sign in. Password-reset emails use the same Gmail sender as Nuxt,
`harrison.tech.contact@gmail.com`, through `smtp.gmail.com:587` with STARTTLS. The local
`.env` supplies the Gmail App Password without committing it to this repository. Keep
the store Mail from address aligned with this sender. Reset links return to the Nuxt
reset-password page. Mailpit remains available at `http://localhost:8025` for explicitly
configured local-only delivery, but does not capture messages sent through Gmail.

### Local startup

Start Docker Desktop, then run from this directory:

```bash
npx spree dev
```

The existing `npm run dev` shortcut also works. The local API is at
`http://localhost:3001` and the dashboard development server is at
`http://localhost:5173` with the current local port settings.
The installed CLI does not support `spree dev --no-open`.

`docker-compose.yml` mounts only the strategy directory and its initializer
read-only into the existing official image. No eject, database switch or new
authentication table is needed for this extension. The existing database and
storage volumes are retained.

The matching PUBLIC key is configured in the project-root `.env`:

```dotenv
FUTURE_CAREER_ASSERTION_PUBLIC_KEY="<RSA public PEM; escaped newline characters are supported>"
FUTURE_CAREER_ASSERTION_KEY_ID=future-career-v1
FUTURE_CAREER_ASSERTION_ISSUER=future-career-auth
FUTURE_CAREER_ASSERTION_AUDIENCE=spree-future-career-auth
```

These values correspond to Nuxt's `SPREE_ASSERTION_*` settings. Keep the private
key exclusively on Nuxt. Nuxt additionally uses a server-only
`SPREE_ADMIN_API_KEY` with `read_customers,write_customers` scopes when a verified
Magic Link needs to resolve or create an unmapped Customer. Store requests still
use their separate publishable key.

After changing Ruby files, run `npx spree restart`. After changing environment
values or compose mounts, stop the foreground process and run `npx spree dev`
again so the container is recreated; restart alone does not apply those changes.
Logs are available with `npx spree logs`.

### Verification and deployment

With Spree running, execute isolated authentication tests without touching its database:

```bash
bun --no-env-file scripts/test-future-career-auth.cjs
```

For production, build the existing `server/Dockerfile` through
`npx spree build --production --tag <your-registry>/my-store:<version>` and deploy
that image. It includes the strategy and initializer. Configure the matching public
key on the production service and retain its database and Rails encryption keys.
The short assertion is not a single-use credential: Nuxt separately enforces
single-use Magic Links. No refresh-token flow is added to Future Career.

## Customizing the Spree API

The `server/` directory is the Spree API — a full Rails application serving the Store and Admin APIs (plus background jobs and transactional emails) that your storefront and dashboard talk to. This project uses a prebuilt Docker image with the two Future Career authentication mounts described above. Other local server changes require a source build. Switching through eject uses a fresh development database, so preserve any existing data before choosing this workflow:

```bash
npx spree eject
```

This rebuilds the Docker image from `server/` and restarts services. You can then:

- **Customize the API** by editing the files in `server/`
- **Add gems** to `server/Gemfile`
- **Add new resources** with `spree generate model <name> <attributes>`

## Spree CLI

This project uses [`@spree/cli`](https://spreecommerce.org/docs/developer/cli/quickstart) to manage the Spree API.

### Services

| Command | Description |
|---------|-------------|
| `spree dev` | Run the app in the foreground — streams logs, Ctrl+C stops it. First run completes setup automatically |
| `spree stop` | Stop the API services |
| `spree upgrade` | Upgrade Spree — the server, database and `@spree/*` packages |
| `spree eject` | Switch from prebuilt image to building from `server/` |
| `spree build --production` | Build the production image — includes `apps/dashboard` when present |
| `spree logs` | View web server logs |
| `spree logs worker` | View background jobs logs |
| `spree console` | Open Rails console |

### Data

| Command | Description |
|---------|-------------|
| `spree migrate` | Install pending Spree migrations from gems, then run them or just run your own migrations |
| `spree seed` | Seed the database |
| `spree sample-data` | Load sample products, categories, images |

### Users & API Keys

| Command | Description |
|---------|-------------|
| `spree user create` | Create an admin user |
| `spree api-key create` | Create a publishable or secret API key |
| `spree api-key list` | List all API keys |
| `spree api-key revoke <id>` | Revoke an API key (ID from `api-key list`) |

### Generators

| Command | Description |
|---------|-------------|
| `spree generate model Brand name:string slug:string:uniq` | Generate a new database model |
| `spree generate api_resource Brand name:string slug:string:uniq` | Generate a new Spree API resource |
| `spree generate subscriber OmsOrderSync order.placed` | Generate a new event subscriber |
| `spree generate migration AddPositionToSpreeBrands position:integer` | Generate a new database migration |

### Admin API

Project setup mints a read-only secret key into `.spree/credentials.json` (gitignored), so the Admin API client works out of the box. If you skipped the setup step, `spree api` mints the key on first use instead:

```bash
npx spree api get products
npx spree api get "orders?q[status_eq]=complete"
npx spree api endpoints          # list endpoints + required scopes
npx spree api status             # show resolved credentials + server reachability
```

The pre-configured key is read-only. To write, create a scoped secret key and pass it via `SPREE_API_KEY`:

```bash
npx spree api-key create --scopes write_products
SPREE_API_KEY=sk_... npx spree api post products --data '{"name":"New product","prices":[{"currency":"USD","amount":"29.99"}]}'
```

| Command | Description |
|---------|-------------|
| `spree api get/post/patch/delete <path>` | Call the Admin API directly |
| `spree api endpoints` | List Admin API endpoints with required scopes |
| `spree auth login --profile <name>` | Save named credentials for a remote store |

> **Running `spree` directly.** The commands above use `npx` because `@spree/cli` is a local project dependency. You can also run any of the package scripts (e.g. `npm run api -- get products`), or install the CLI globally for a bare `spree` command:
>
> ```bash
> npm install -g @spree/cli
> spree api get products
> ```

## Learn More

- [Spree Documentation](https://spreecommerce.org/docs)
- [Spree Discord](https://discord.spreecommerce.org)
- [Store API Reference](https://spreecommerce.org/docs/api-reference/store-api/introduction)
- [Admin API Reference](https://spreecommerce.org/docs/api-reference/admin-api/introduction)
- [CLI Reference](https://spreecommerce.org/docs/developer/cli/quickstart)
- [Spree GitHub](https://github.com/spree/spree)
# spree-test
