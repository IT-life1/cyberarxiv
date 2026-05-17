# ============================================================
# CyberArXiv R Package + Dashboard
# ============================================================
FROM rocker/r-ver:4.3.2

# Fix: Use noble (24.04) mirror URL matching the base image
RUN --mount=type=cache,target=/var/cache/apt \
        --mount=type=cache,target=/var/lib/apt \
        apt-get update && apt-get install -y --no-install-recommends \
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
        && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/cyberarxiv

# Fix: Use CRAN mirror directly instead of P3M jammy (which doesn't match noble base)
RUN echo 'options(repos = c(CRAN = "https://cloud.r-project.org"))' \
    >> "${R_HOME}/etc/Rprofile.site"

ENV MAKEFLAGS="-j2"

RUN R -e 'install.packages("pak")'

COPY DESCRIPTION NAMESPACE /srv/cyberarxiv/
COPY R/ /srv/cyberarxiv/R/
COPY man/ /srv/cyberarxiv/man/
COPY inst/ /srv/cyberarxiv/inst/
# Fix: Copy data directory for built-in dataset
COPY data/ /srv/cyberarxiv/data/

RUN R -e 'library(pak); local_install("/srv/cyberarxiv", dependencies = TRUE)'

# Дополнительно ставим shiny, DT и rhandsontable для GUI
RUN R -e 'install.packages(c("shiny", "DT", "rhandsontable"))'

COPY docker/ /srv/cyberarxiv/docker/
RUN chmod +x /srv/cyberarxiv/docker/run_etl.R \
    /srv/cyberarxiv/docker/run_shiny.R \
    /srv/cyberarxiv/docker/start.sh

RUN mkdir -p /srv/cyberarxiv/data /srv/cyberarxiv/raw-data

ENV CYBERARXIV_DB_PATH=/srv/cyberarxiv/data/cyberarxiv.duckdb
ENV ML_SERVICE_URL=http://cyberarxiv-ml:5001

EXPOSE 3838

CMD ["/srv/cyberarxiv/docker/start.sh"]
