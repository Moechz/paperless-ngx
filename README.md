# paperless-ngx-for-tos

> TerraMaster TOS 7 App Center — **Docker application** package for
> [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx).

## What this is

A four-file TOS Docker application archive (`paperlessngxdocker.tar.gz`) that installs
Paperless-ngx on TOS 7 through the App Center:

- `config.ini` — TOS application metadata (`application_type: docker`, id `paperlessngxdocker`)
- `paperlessngxdocker.lang` — 23-language superset (TOS requires 14)
- `paperlessngxdocker.svg` — application icon (540 bytes, 2 SVG elements)
- `docker-compose.yml` — one service, image `paperlessngx/paperless-ngx:3.2.1`

## How it works

| | |
|---|---|
| Container image | `paperlessngx/paperless-ngx:3.2.1` (Docker Hub, used unmodified) |
| Open | `http://<NAS-IP>:8011/` (container port 8000) |
| Runs as | non-root, `user: "1000:1000"` |
| Persistent data | `/usr/src/paperless/data` → `/Volume1/DockerAppData/paperlessngxdocker/data`, `/usr/src/paperless/media` → `/Volume1/DockerAppData/paperlessngxdocker/media`, `/usr/src/paperless/consume` → `/Volume1/DockerAppData/paperlessngxdocker/consume`, `/usr/src/paperless/export` → `/Volume1/DockerAppData/paperlessngxdocker/export` |
| Logs | `docker logs paperlessngxdocker` (stdout/stderr) |

The four mounted folders are the whole application: `consume` is watched - every file placed there is imported, OCRed and moved into `media`; `data` holds the SQLite database, the OCR text, the search index, the auto-generated `secret-key`, the first administrator password and `extra-env.txt`; `media` holds the original documents and previews; `export` receives bulk exports from the web UI.

## Design highlights

- **Non-root.** `user: "1000:1000"`; verified on real hardware (the container reports uid 1000).
- **Entrypoint wrapper (not for privileges)**: the upstream image already runs its stack as the unprivileged `paperless` user, so the wrapper is not about privileges. `src/entrypoint.sh` generates the required `PAPERLESS_SECRET_KEY` once and keeps it in the data volume, creates the first administrator with a random password (stored in `data/admin-password.txt`), applies the optional `data/extra-env.txt`, and then hands over to the unchanged upstream `init` (`/init`).
- **Fixed image tag, never `:latest`**, Docker Hub only, no `privileged`, no `network_mode: host`, and no Docker socket, no `cap_add`.
- **Health check** probing the service on container port 8000.
- **Deterministic build**: GNU tar with uid/gid 0 and zeroed timestamps, gzip without a timestamp, plus the review-standards self-check above.
- **Works as a non-root container.** The upstream image starts s6-overlay as root by default; verified on real hardware that the whole stack (init, migrations, Granian web server, Celery worker and beat) runs with `user: "1000:1000"`, which is exactly the image's own `paperless` user.
- **The required secret key is generated once and kept.** The image refuses to start with its shipped default key. `src/entrypoint.sh` creates a unique key with the CSPRNG and stores it in the data volume, so it survives updates and re-installs, and a restore keeps working sessions.
- **A first administrator without a shared password.** The wrapper creates user `admin` with a random password and leaves it in `data/admin-password.txt` (plus the container log), so no two installations share credentials and there is no manual `createsuperuser` step.
- **A supported way to set environment-only options.** Paperless is configured exclusively through environment variables; `data/extra-env.txt` (seeded with commented examples for the OCR language and the public URL) applies them on every start without editing the package.
- **Two containers, one published port.** The image needs a Redis-compatible broker, so the compose project runs `paperlessngx/paperless-ngx` plus `valkey/valkey:9-alpine`. Only the Paperless web server publishes a host port; the broker runs without persistence, because it only carries the task queue.
- **Health check** probing the Paperless web server on container port 8000.

## Runtime file manifest

Everything the application writes on the NAS lives inside its own data
directory; the container-internal `/tmp` is discarded with the container. The
table lists what is created and how it behaves. Nothing else is written.

| Path | Purpose | Created when | Growth bound | Lifecycle |
|---|---|---|---|---|
| `data/secret-key` | PAPERLESS_SECRET_KEY, generated once and used to sign sessions | first start | static | never overwritten; a restore without it invalidates every session |
| `data/admin-password.txt` | password of the automatically created first administrator | first start | static | never overwritten; only used while no superuser exists |
| `data/extra-env.txt` | optional environment settings (OCR language, public URL, mail, ...) | first start | user controlled | never overwritten; edit it and restart the application |
| `data/db.sqlite3` | documents, tags, correspondents, users and the task queue state (SQLite database) | first start (migrations) | grows with every imported document | never overwritten; back it up before uninstalling with data removal |
| `data/index` | full-text search index built from the OCR text | first start | roughly the size of the extracted text | rebuildable from the documents if it is lost |
| `media` | the original documents and the generated previews and thumbnails | with the first imported document | grows with every archived document | never overwritten; this is your archive |
| `consume` | watched folder - every file placed here is imported and then removed | first start | bounded by what you drop in | managed by Paperless |
| `export` | destination for the bulk exports triggered in the web UI | first start | grows with the exports you run | safe to delete |
| `/Volume1/DockerAppData/paperlessngxdocker/data` | Paperless-ngx application data (everything the container writes outside /tmp) | on first start / on demand | bounded by your own data | persistent; kept on uninstall unless you ask to delete it |
| `/Volume1/DockerAppData/paperlessngxdocker/media` | Paperless-ngx application data (everything the container writes outside /tmp) | on first start / on demand | bounded by your own data | persistent; kept on uninstall unless you ask to delete it |
| `/Volume1/DockerAppData/paperlessngxdocker/consume` | Paperless-ngx application data (everything the container writes outside /tmp) | on first start / on demand | bounded by your own data | persistent; kept on uninstall unless you ask to delete it |
| `/Volume1/DockerAppData/paperlessngxdocker/export` | Paperless-ngx application data (everything the container writes outside /tmp) | on first start / on demand | bounded by your own data | persistent; kept on uninstall unless you ask to delete it |

## Build

```bash
scripts/build.sh                  # -> out/paperlessngxdocker.tar.gz + .sha256
scripts/build.sh 3.2.1-2   # packaging iteration bump
scripts/build.sh 3.2.1-1 aarch64
```

The build stages the four files, substitutes the version/platform placeholders,
embeds `src/entrypoint.sh` into the compose file (escaping every `$` as `$$`), removes CRLF/BOM/AppleDouble, then runs
`tools/verify.py`, a review-standards self-check (archive layout, JSON validity,
required fields, 14+ language coverage, version consistency, Docker-Hub-only
images, fixed tag, reserved/recommended host ports, non-root user, per-service
healthcheck/TZ/restart, data path below the application data root, never the
`/Volume*` wildcard, comment-free sequence blocks, `x-app-meta` position, no
literal secrets and the SVG size/element limits).

## Local verification

```bash
./TOSAppSelfTestingTool -c out/paperlessngxdocker.tar.gz   # official spec check
bash test/install-and-verify.sh                  # on-device E2E (needs root)
```

> Docker applications cannot be side-loaded through the App Center's manual
> install page (it accepts `.deb` only); the official self-testing tool's `-i`
> mode or `docker compose` are the only ways to install one for testing.

## Store submission checklist

1. Public GitHub repo (code + README only).
2. Release **tag `v3.2.1-1`**, assets `paperlessngxdocker.tar.gz` +
   `paperlessngxdocker.tar.gz.sha256` (Docker asset naming: `<app_id>.tar.gz`, **no
   platform suffix**).
3. Developer platform → Add Application: ID `paperlessngxdocker`, package type Docker,
   repository URL, architecture `x86_64`.
4. Version Management → Add Version `3.2.1-1` → automated validation → review.

## License / branding

Paperless-ngx is distributed by its upstream authors under **GPL-3.0**. The container image is the official image from Docker Hub (`paperlessngx/paperless-ngx:3.2.1`) and is used unmodified; no upstream source code is redistributed here. This packaging is an independent community submission by Moechz and is not affiliated with the upstream project or TerraMaster.

## Limitations

Only one host port is published, and automatic HTTPS is not available. Do not expose the port to the internet without a TLS reverse proxy.
OCR defaults to English. To scan other languages, add them in `data/extra-env.txt` (for example `PAPERLESS_OCR_LANGUAGES=chi_sim` together with `PAPERLESS_OCR_LANGUAGE=chi_sim+eng`) and restart the application; the additional traineddata files are downloaded on first use.
E-mail links and the share links Paperless generates use `http://localhost:8000` until you set `PAPERLESS_URL` in `data/extra-env.txt` to `http://<NAS-IP>:8011`.
Paperless and its broker are two containers of the same application. Stopping or removing one of them outside the App Center leaves the other behind; use the App Center (or `docker compose`) so both are handled together.
The bundled database is SQLite, which is fine for personal and small-office archives. For very large archives PostgreSQL is more suitable, but that requires editing the compose file.

---

Packaged for TOS 7 by Moechz. Upstream image used unmodified from Docker Hub.
