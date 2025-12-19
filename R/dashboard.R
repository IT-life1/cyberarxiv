#' Render the cyberarxiv dashboards
#'
#' This helper renders either the lightweight R Markdown dashboard
#' (docker/dashboard.Rmd) or the richer Quarto dashboard
#' (inst/quarto/dashboard.qmd) and optionally opens the result in a browser.
#'
#' @param engine Either "rmarkdown" (default) or "quarto" to select which
#'   dashboard source to render.
#' @param output_dir Directory where the rendered HTML (dashboard.html) will be
#'   written. Defaults to `_site` to align with the existing scripts.
#' @param open_browser Logical; if TRUE (default when interactive) the rendered
#'   HTML file is opened via `utils::browseURL()`.
#' @param ... Additional arguments passed to `rmarkdown::render()` when
#'   `engine = "rmarkdown"` or to `quarto::quarto_render()` when
#'   `engine = "quarto"`.
#'
#' @return Invisibly returns the path to the rendered HTML file.
#' @export
render_dashboard <- function(engine = c("rmarkdown", "quarto"),
                             output_dir = "_site",
                             open_browser = interactive(),
                             ...) {
  engine <- match.arg(engine)
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  if (engine == "rmarkdown") {
    src <- file.path("docker", "dashboard.Rmd")
    if (!file.exists(src)) {
      stop("Dashboard source not found at ", src)
    }
    output_file <- file.path(output_dir, "dashboard.html")
    rmarkdown::render(src, output_file = output_file, ...)
  } else {
    src <- file.path("inst", "quarto", "dashboard.qmd")
    if (!file.exists(src)) {
      stop("Quarto dashboard source not found at ", src)
    }
    if (!requireNamespace("quarto", quietly = TRUE)) {
      stop("Package 'quarto' is required to render the Quarto dashboard.")
    }
    output_basename <- "dashboard.html"
    quarto::quarto_render(src, output_file = output_basename, ...)
    rendered_file <- file.path(dirname(src), output_basename)
    if (!file.exists(rendered_file)) {
      stop("Quarto render did not produce ", rendered_file)
    }
    output_file <- file.path(output_dir, output_basename)
    file.copy(rendered_file, output_file, overwrite = TRUE)
  }

  if (open_browser && file.exists(output_file)) {
    utils::browseURL(normalizePath(output_file))
  }

  invisible(output_file)
}
