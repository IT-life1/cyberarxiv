#!/usr/bin/env Rscript
options(repos = 'https://cloud.r-project.org')
log <- function(...) cat(sprintf("[%s] ", Sys.time()), ..., "\n")

log("Rendering dashboard.Rmd to _site/dashboard.html")
if (!requireNamespace('rmarkdown', quietly = TRUE)) {
  install.packages('rmarkdown')
}

outdir <- '_site'
dir.create(outdir, showWarnings = FALSE)

rmarkdown::render(input = 'docker/dashboard.Rmd', output_file = file.path(outdir, 'dashboard.html'))
log('Rendered to', file.path(outdir, 'dashboard.html'))
