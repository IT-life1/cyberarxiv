#!/usr/bin/env Rscript
options(repos = 'https://cloud.r-project.org')
log <- function(...) cat(sprintf("[%s] ", Sys.time()), ..., "\n", file = stderr())

site_dir <- '/var/www/html'
dir.create(site_dir, showWarnings = FALSE, recursive = TRUE)

if (!requireNamespace('cyberarxiv', quietly = TRUE)) {
  stop('Package cyberarxiv is not installed; ensure the Docker image installed it.')
}

log('Rendering and serving dashboard from', site_dir)
cyberarxiv::serve_dashboard(output_dir = site_dir, quiet = TRUE)
