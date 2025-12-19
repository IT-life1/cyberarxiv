FROM rocker/r-ver:4.5.1

RUN apt-get update && apt-get install -y --no-install-recommends \
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

COPY . /srv/cyberarxiv

RUN R -e "options(repos='https://cloud.r-project.org'); install.packages(c('remotes','renv'))"

RUN R -e "if (file.exists('renv.lock')) renv::restore(prompt = FALSE)"

RUN R CMD INSTALL --no-multiarch --with-keep.source /srv/cyberarxiv

RUN apt-get update && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*

COPY docker/run_etl.R /srv/cyberarxiv/docker/run_etl.R
COPY docker/run_dashboard.R /srv/cyberarxiv/docker/run_dashboard.R
COPY docker/serve_dashboard.sh /srv/cyberarxiv/docker/serve_dashboard.sh
RUN chmod +x /srv/cyberarxiv/docker/run_etl.R /srv/cyberarxiv/docker/run_dashboard.R /srv/cyberarxiv/docker/serve_dashboard.sh

CMD ["Rscript", "/srv/cyberarxiv/docker/run_etl.R"]
