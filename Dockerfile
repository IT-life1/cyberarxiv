# syntax=docker/dockerfile:1.4
FROM rocker/r-ver:4.5.1

# 1) Install eatmydata first for faster apt operations
RUN --mount=type=cache,target=/var/cache/apt \
        --mount=type=cache,target=/var/lib/apt \
        apt-get update && apt-get install -y --no-install-recommends \
            eatmydata \
        && rm -rf /var/lib/apt/lists/*

# 2) Install system dependencies with eatmydata for reduced I/O sync calls
RUN --mount=type=cache,target=/var/cache/apt \
        --mount=type=cache,target=/var/lib/apt \
        eatmydata apt-get update && eatmydata apt-get install -y --no-install-recommends \
            build-essential \
            libcurl4-openssl-dev \
            libssl-dev \
            libxml2-dev \
            pkg-config \
            libglpk-dev \
            libfontconfig1-dev \
            libfreetype6-dev \
            libpng-dev \
            libicu-dev \
            wget \
            ca-certificates \
            gnupg \
        && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/cyberarxiv

# 3) Configure R package repositories (use cloud.r-project.org as primary)
RUN echo 'options(repos = c(CRAN = "https://cloud.r-project.org/"))' \
    >> "${R_HOME}/etc/Rprofile.site"

# 4) Enable parallel compilation for source packages
ENV MAKEFLAGS="-j$(nproc)"

# 5) Install pak for fast package management
RUN R -e 'install.packages("pak", repos = "https://cloud.r-project.org")'

# 6) Install stringi with proper ICU dependencies
RUN R -e 'install.packages("stringi", repos = "https://cloud.r-project.org")'

# 7) Install Quarto CLI using a specific version for reliability and caching
ARG QUARTO_VERSION="1.8.26"
RUN wget -q -O /tmp/quarto.deb "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb" \
 && eatmydata apt-get update \
 && eatmydata apt-get install -y --no-install-recommends /tmp/quarto.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/quarto.deb

# 8) Copy package source code
COPY DESCRIPTION NAMESPACE /srv/cyberarxiv/
COPY R/ /srv/cyberarxiv/R/
COPY man/ /srv/cyberarxiv/man/
COPY inst/ /srv/cyberarxiv/inst/

# 9) Install local package with dependencies using pak
RUN R -e 'library(pak); pak::local_install("/srv/cyberarxiv", dependencies = TRUE)'

# 10) Copy docker scripts and set permissions
COPY docker/ /srv/cyberarxiv/docker/
RUN chmod +x /srv/cyberarxiv/docker/run_etl.R \
    /srv/cyberarxiv/docker/run_dashboard.R \
    /srv/cyberarxiv/docker/serve_dashboard.sh \
    /srv/cyberarxiv/docker/start.sh

# 11) Create data directories
RUN mkdir -p /srv/cyberarxiv/data /srv/cyberarxiv/raw-data /var/www/html

# 12) Set environment variables
ENV CYBERARXIV_DB_PATH=/srv/cyberarxiv/data/cyberarxiv.duckdb

EXPOSE 8000

CMD ["/srv/cyberarxiv/docker/start.sh"]