# syntax=docker/dockerfile:1.4
FROM rocker/r-ver:4.5.1

# 1) Системные зависимости (и кеш apt)
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      libcurl4-openssl-dev \
      libssl-dev \
      libxml2-dev \
      pkg-config \
      libglpk-dev \
      libsqlite3-dev \
      libfontconfig1-dev \
      libharfbuzz-dev \
      libfribidi-dev \
      libfreetype6-dev \
      libpng-dev \
      libjpeg-dev \
      libicu-dev \
      wget \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/cyberarxiv

# 2) Репозитории: P3M (бинарники) + CRAN (fallback)
# Rocker сам часто уже ставит P3M, но мы фиксируем “правильно” и надёжно. :contentReference[oaicite:3]{index=3}
RUN echo 'options(repos = c(P3M = "https://packagemanager.posit.co/cran/__linux__/jammy/latest", CRAN = "https://cloud.r-project.org"))' \
    >> "${R_HOME}/etc/Rprofile.site"

# 3) Ускоряем сборку из исходников (если вдруг всё же придётся компилить)
ENV MAKEFLAGS="-j$(nproc)"

# 4) Ставим renv (и pak опционально — часто быстрее качает/ставит)
RUN R -e 'options(repos = c(CRAN="https://cloud.r-project.org")); install.packages(c("renv","pak"))'

# 5) КЛЮЧЕВОЕ: сначала копируем ТОЛЬКО то, что влияет на restore
COPY renv.lock renv.lock
# если есть — тоже полезно для кеша:
# COPY renv/settings.json renv/settings.json

# 6) restore с кешем renv
ENV RENV_CONFIG_PPM_ENABLED=TRUE
ENV RENV_CONFIG_PAK_ENABLED=TRUE
RUN --mount=type=cache,id=renv-cache,target=/root/.local/share/renv/cache \
    R -e 'renv::restore(prompt = FALSE)'

# 7) Теперь копируем остальной проект (это уже НЕ ломает слой restore)
COPY . .

RUN R CMD INSTALL --no-multiarch --with-keep.source .

RUN apt-get update && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*

COPY docker/run_etl.R /srv/cyberarxiv/docker/run_etl.R
COPY docker/run_dashboard.R /srv/cyberarxiv/docker/run_dashboard.R
COPY docker/serve_dashboard.sh /srv/cyberarxiv/docker/serve_dashboard.sh
RUN chmod +x /srv/cyberarxiv/docker/run_etl.R /srv/cyberarxiv/docker/run_dashboard.R /srv/cyberarxiv/docker/serve_dashboard.sh

CMD ["Rscript", "/srv/cyberarxiv/docker/run_etl.R"]
