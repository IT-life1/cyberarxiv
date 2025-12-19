#' Render the cyberarxiv Quarto dashboard
#'
#' This helper renders the Quarto dashboard located in
#' `inst/quarto/dashboard.qmd` (when the package is installed) or a user
#' provided `.qmd` file and optionally opens the result in a browser.
#'
#' @param source Path to a Quarto `.qmd` file. Defaults to the package's
#'   `inst/quarto/dashboard.qmd` when `NULL`.
#' @param output_dir Directory where the rendered HTML (dashboard.html) will be
#'   written. Defaults to `_site` to align with the existing scripts.
#' @param open_browser Logical; if TRUE (default when interactive) the rendered
#'   HTML file is opened via `utils::browseURL()`.
#' @param ... Additional arguments passed to `quarto::quarto_render()`.
#'
#' @return Invisibly returns the path to the rendered HTML file.
#' @export
render_dashboard <- function(source = NULL,
                             output_dir = "_site",
                             open_browser = interactive(),
                             ...) {
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
  if (is.null(source)) {
    pkg_path <- tryCatch(find.package("cyberarxiv"), error = function(e) NA_character_)
    candidate <- if (!is.na(pkg_path)) file.path(pkg_path, "quarto", "dashboard.qmd") else ""
    if (!nzchar(candidate) || !file.exists(candidate)) {
      candidate <- file.path("inst", "quarto", "dashboard.qmd")
    }
    source <- candidate
  }
  if (!file.exists(source)) {
    stop("Quarto dashboard source not found at ", source)
  }
  if (!requireNamespace("quarto", quietly = TRUE)) {
    stop("Package 'quarto' is required to render the Quarto dashboard.")
  }
  output_basename <- "dashboard.html"
  quarto::quarto_render(source, output_file = output_basename, ...)
  rendered_file <- file.path(dirname(source), output_basename)
  if (!file.exists(rendered_file)) {
    stop("Quarto render did not produce ", rendered_file)
  }
  output_file <- file.path(output_dir, output_basename)
  file.copy(rendered_file, output_file, overwrite = TRUE)

  if (open_browser && file.exists(output_file)) {
    utils::browseURL(normalizePath(output_file))
  }

  invisible(output_file)
}
