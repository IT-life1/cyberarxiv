![R-CMD-check](https://github.com/IT-life1/cyberarxiv/actions/workflows/R-CMD-check.yml/badge.svg)

# cyberarxiv

R-пакет для сбора, хранения и анализа научных публикаций arXiv
по тематике кибербезопасности.

## Docker Compose

This repository includes a `docker-compose.yml` that builds the package image and provides two services:

- `app` — runs the ETL (`docker/run_etl.R`) and writes data into `./data`.
- `web` — renders (if needed) and serves the dashboard static site at http://localhost:8000.

Usage:

1. Build and start services in background:

```bash
docker-compose up --build -d
```

2. Visit the dashboard at: http://localhost:8000

3. The package data directory on the host is `./data` and is mounted into the container at `/srv/cyberarxiv/data` so DB updates persist across restarts.

Run only the web service (after a prior ETL) with:

```bash
docker-compose up --build -d web
```

To run the ETL once:

```bash
docker-compose run --rm app
```

Notes:

- The Docker image is built from the project root and installs package dependencies via `renv::restore()` if `renv.lock` is present.
- If you need a database container (Postgres) instead of a file-based DB, I can add a `db` service and update the package configuration.

