FROM rocker/r-ver:4.5.1

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

RUN echo 'options(repos = c(P3M = "https://packagemanager.posit.co/cran/__linux__/jammy/latest", CRAN = "https://mirror.truenetwork.ru/CRAN/"))' \
    >> "${R_HOME}/etc/Rprofile.site"

ENV MAKEFLAGS="-j$(nproc)"

RUN R -e 'install.packages("pak", repos = c(CRAN = "https://mirror.truenetwork.ru/CRAN/"))'

RUN R -e 'if (requireNamespace("stringi", quietly = TRUE)) { remove.packages("stringi"); }; install.packages("stringi", repos = c(CRAN = "https://mirror.truenetwork.ru/CRAN/"))'

RUN wget -q -O /tmp/quarto.deb https://quarto.org/download/latest/quarto-linux-amd64.deb \
 && apt-get update \
 && apt-get install -y --no-install-recommends /tmp/quarto.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/quarto.deb

COPY DESCRIPTION NAMESPACE /srv/cyberarxiv/
COPY R/ /srv/cyberarxiv/R/
COPY man/ /srv/cyberarxiv/man/
COPY inst/ /srv/cyberarxiv/inst/

RUN R -e 'library(pak); local_install("/srv/cyberarxiv", dependencies = TRUE)'

COPY docker/ /srv/cyberarxiv/docker/
RUN chmod +x /srv/cyberarxiv/docker/run_etl.R \
    /srv/cyberarxiv/docker/run_dashboard.R \
    /srv/cyberarxiv/docker/serve_dashboard.sh \
    /srv/cyberarxiv/docker/start.sh

RUN mkdir -p /srv/cyberarxiv/data /srv/cyberarxiv/raw-data /var/www/html

ENV CYBERARXIV_DB_PATH=/srv/cyberarxiv/data/cyberarxiv.duckdb

EXPOSE 8000

CMD ["/srv/cyberarxiv/docker/start.sh"]
