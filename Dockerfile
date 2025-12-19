# syntax=docker/dockerfile:1.4
FROM rocker/r-ver:4.5.1

# 1) Системные зависимости (и кеш apt)
RUN --mount=type=cache,target=/var/cache/apt \
        --mount=type=cache,target=/var/lib/apt \
        apt-get update && apt-get install -y --no-install-recommends \
            build-essential \
            git \
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
            python3 \
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

# 4) Базовые R инструменты: remotes для установки из GitHub
RUN R -e 'install.packages("remotes", repos = c(CRAN = "https://cloud.r-project.org"))'

# 5) Устанавливаем Quarto CLI для `quarto::quarto_render()`
RUN wget -q -O /tmp/quarto.deb https://quarto.org/download/latest/quarto-linux-amd64.deb \
 && apt-get update \
 && apt-get install -y --no-install-recommends /tmp/quarto.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/quarto.deb

# 6) Ставим пакет напрямую из GitHub (вместе со всеми зависимостями)
RUN R -e 'remotes::install_github("IT-life1/cyberarxiv", dependencies = TRUE, upgrade = "never")'

# 7) Копируем docker-скрипты проекта внутрь образа
COPY docker/ /srv/cyberarxiv/docker/
RUN chmod +x /srv/cyberarxiv/docker/run_etl.R /srv/cyberarxiv/docker/run_dashboard.R /srv/cyberarxiv/docker/serve_dashboard.sh

CMD ["Rscript", "/srv/cyberarxiv/docker/run_etl.R"]
