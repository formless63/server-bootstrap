---
name: new-project
description: Conventions for starting a new project or compose stack on this server. Covers where code vs. running stacks live (~/projects, ~/stacks), compose naming and restart rules, networking via the Pangolin connector, and preferred starter stacks. Use whenever creating a new project, repo, service, or docker compose stack, or adding compose files to an existing project.
---

# New project / stack conventions

## Where things live

- **Code:** `~/projects/<name>/`, one git repo per project.
- **Running stacks:** `~/stacks/<name>/`. Dockhand (via the Hawser agent) manages everything in `~/stacks`, so a stack must live here to be visible and manageable.
- `<name>` is short and kebab-case, and the **same** across the project folder, stack folder and compose `name:`.

### Dev project with compose

The repo carries the *example*. The stack folder carries the *real* config:

```
~/projects/<name>/
  compose.example.yaml   # committed; shows how to run it (uses image: or build: .)
  .env.example           # committed; every variable, no real secrets
  .gitignore             # includes .env, compose.override.yaml, data/
~/stacks/<name>/
  compose.yaml           # what we actually run/test (copied from the example, then adjusted)
  .env                   # real values; never committed anywhere
  data/                  # bind-mounted state, if any
```

- To test local code from a stack, point `build.context` at the absolute repo path (`/home/wicaso/projects/<name>`), never a relative `../../projects/...`.
- Keep `compose.example.yaml` in sync when the real stack's shape changes (new services, env vars, volumes). Real values stay out of the repo.
- Infra or third-party stacks (no code of ours) only get `~/stacks/<name>/`, with no project folder.

## Compose rules

1. **Name everything** so Compose never appends `-1` or prefixes things:
   - Top-level `name: <name>`.
   - `container_name:` on every service, as `<name>` for the main service and `<name>-<service>` for the rest (e.g. `myapp`, `myapp-db`).
   - Every named volume and network gets an explicit `name:`.
2. **`restart: unless-stopped`** on every long-running service. Exceptions use `restart: "no"`:
   - one-shot jobs (migrations, seeders, init containers)
   - dev-only services (watchers, dev servers, debug tools) or anything that would crash-loop while you're iterating
3. **Never expose ports to the public internet (WAN) when it can be avoided.**
   - *Public-facing apps:* no published ports. Pangolin reaches them through the external `pangolin` network (created by the Pangolin connector stack).
   - *Internal tooling* (admin UIs, agents, dev servers): publishing a port for access over Tailscale (`<tailscale-ip>:port`) is fine. Prefer binding to the Tailscale IP via `${TAILSCALE_IP}` from `.env` (`"${TAILSCALE_IP}:8080:80"`) or `127.0.0.1:`, rather than a bare `8080:80` on every interface.
   - Docker-published ports bypass ufw, so the bind address is the real access control. Never add router port-forwards.
4. File is `compose.yaml` (not `docker-compose.yml`), and there is no `version:` key.
5. Secrets and environment-specific values go in `.env` (referenced as `${VAR}`), never inline.
6. Relative bind mounts (`./data:/data`) are fine. They resolve inside `~/stacks/<name>/`, and Hawser is mounted at the identical host path, so they work from Dockhand too.
7. Pin images to a major (or exact) version tag where practical, not bare `latest`, for anything stateful (databases especially).

### Template

```yaml
name: myapp

services:
  app:
    container_name: myapp
    image: ghcr.io/example/myapp:1
    # build: /home/wicaso/projects/myapp   # when testing local code
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./data:/data
    networks:
      - default
      - pangolin

  db:
    container_name: myapp-db
    image: postgres:18
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - db:/var/lib/postgresql

volumes:
  db:
    name: myapp-db

networks:
  default:
    name: myapp
  pangolin:
    name: pangolin
    external: true
```

Only the service that Pangolin proxies to joins `pangolin`. Databases and other internals stay on the stack's own network.

## Preferred stacks and starter repos

When one applies, base the new project on it instead of scaffolding from scratch. If the project doesn't clearly fit one, ask the owner. More starters will be added as new dev pathways come up.

| Starter | Use for | Stack |
|---|---|---|
| [formless63/demo-starter-nuxt](https://github.com/formless63/demo-starter-nuxt) | Full-stack web apps, **Vue** | Nuxt 4 / Vue 3 / Nitro, shadcn-vue (Reka UI), ESLint |
| [formless63/demo-starter-tanstack](https://github.com/formless63/demo-starter-tanstack) | Full-stack web apps, **React** | TanStack Start / React, shadcn-style + Base UI, Biome |

Both share the same core: Bun 1.4 (tooling, `bun.lock`, `--frozen-lockfile`), Node 24 for production output, strict TypeScript, PostgreSQL 18 + Drizzle with committed migrations (no schema push), Better Auth (passwordless: GitHub OAuth / OIDC / Pocket ID, optional magic links), Tailwind 4, Tabler Icons, Vitest + Playwright, pg-boss jobs, Pino logging, and Renovate. Each has **29 optional capabilities**. Clean generated projects get none unless they're selected.

Using a starter:
- **The starter's own `AGENTS.md` and onboarding doc govern the project's internals.** Read them first (`docs/STARTING-A-PROJECT.md` for Nuxt, `docs/PROJECT-ONBOARDING.md` for TanStack), and decide up front which capabilities to keep. Removing them later is manual work.
- Starters ship their own `compose.yaml` (plus `compose.preview/cache/email/storage.yaml` overlays). **In the repo, that `compose.yaml` *is* the example.** Don't rename it to `compose.example.yaml`.
- The stack copy in `~/stacks/<name>/compose.yaml` adapts it to this server: add `name:` / `container_name:` / named volumes and networks, drop published ports (e.g. TanStack's `APP_PORT`), put `app` on the `pangolin` network, and keep `postgres` and `worker` internal.
- **The `migrate` and `jobs-migrate` services are one-shot, so they get `restart: "no"`.** `app`, `worker` and `postgres` get `unless-stopped`. The starters treat migrations as an explicit release gate: run `docker compose run --rm migrate` (and `jobs-migrate`) before starting `app` and `worker`.
- Postgres 18 uses the new data path (`/var/lib/postgresql`, not `.../data`). Use whatever volume mount the starter's compose uses.
- Bun and Node 24 are **not** installed on the host yet. Install them (or develop inside containers) before running `bun run dev` locally.

## Checklist for a new project

1. Pick `<name>`. Create `~/projects/<name>` (git init, or clone the starter repo) and/or `~/stacks/<name>`.
2. Write `compose.example.yaml` + `.env.example` in the repo, following the rules above. Add `.env` to `.gitignore`.
3. Copy to `~/stacks/<name>/compose.yaml`, create `.env` with real values, and adjust `build:` to the absolute repo path if testing local code.
4. Validate with `docker compose -f ~/stacks/<name>/compose.yaml config -q`. It should print nothing, and every container should have an explicit name.
5. Bring it up from Dockhand, or with `docker compose up -d` in the stack dir.
6. Note any new long-lived stack under "Installed / configured" in `~/AGENTS.md`.
