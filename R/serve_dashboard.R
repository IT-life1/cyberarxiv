#' Render and serve the cyberarxiv dashboard via httpuv
#'
#' Renders the dashboard and starts an HTTP server based on `httpuv`
#' for serving static files. The function blocks execution while the server runs.
#'
#' @inheritParams render_dashboard
#' @param host Host to listen on (default "0.0.0.0").
#' @param port Port to listen on (default 8000).
#' @return Invisibly returns the server (function blocks execution).
#' @export
serve_dashboard <- function(source = NULL,
                            output_dir = "/var/www/html",
                            quiet = TRUE,
                            host = "0.0.0.0",
                            port = 8000,
                            ...) {
  if (!requireNamespace("httpuv", quietly = TRUE)) {
    stop("Package 'httpuv' is required. Install it with: install.packages('httpuv')")
  }

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  render_dashboard(
    source = source,
    output_dir = output_dir,
    quiet = quiet,
    ...
  )

  output_path <- normalizePath(output_dir, winslash = "/", mustWork = TRUE)
  message("Dashboard rendered to ", output_path)
  message("Starting httpuv server on http://", host, ":", port, " ...")

  # Create handler for static files
  app <- list(
    call = function(req) {
      path <- req$PATH_INFO

      # If path is empty or "/", serve dashboard.html
      if (path == "" || path == "/") {
        path <- "/dashboard.html"
      }

      # FIX: Robust path traversal protection
      # 1) URL-decode the path
      path_decoded <- httpuv::decodeURIComponent(path)
      # 2) Remove leading slash
      normalized_path <- sub("^/+", "", path_decoded)
      # 3) Repeatedly resolve ../ and ./ until stable
      prev <- ""
      while (prev != normalized_path) {
        prev <- normalized_path
        normalized_path <- gsub("/\\./", "/", normalized_path)       # /./ -> /
        normalized_path <- gsub("/[^/]+/\\.\\./", "/", normalized_path)  # /foo/../ -> /
        normalized_path <- gsub("^\\.\\./", "", normalized_path)      # leading ../
        normalized_path <- gsub("^\\./", "", normalized_path)         # leading ./
      }

      file_path <- file.path(output_path, normalized_path)

      # 4) Final check: resolved path must start with output_path
      file_path_resolved <- normalizePath(file_path, winslash = "/", mustWork = FALSE)
      if (!startsWith(file_path_resolved, output_path)) {
        return(list(
          status = 403L,
          headers = list(
            "Content-Type" = "text/plain",
            "X-Content-Type-Options" = "nosniff"
          ),
          body = "403 Forbidden"
        ))
      }

      # Check file exists
      if (file.exists(file_path_resolved) && !dir.exists(file_path_resolved)) {
        ext <- tools::file_ext(file_path_resolved)
        content_type <- switch(
          ext,
          html = "text/html; charset=utf-8",
          css = "text/css",
          js = "application/javascript",
          json = "application/json",
          png = "image/png",
          jpg = "image/jpeg",
          jpeg = "image/jpeg",
          gif = "image/gif",
          svg = "image/svg+xml",
          ico = "image/x-icon",
          "application/octet-stream"
        )

        # FIX: Stream file in chunks instead of reading entire file into memory
        file_size <- file.info(file_path_resolved)$size
        body <- readBin(file_path_resolved, "raw", min(file_size, 10 * 1024 * 1024))  # cap at 10MB

        list(
          status = 200L,
          headers = list(
            "Content-Type" = content_type,
            "Content-Length" = as.character(length(body)),
            "X-Content-Type-Options" = "nosniff",
            "X-Frame-Options" = "DENY"
          ),
          body = body
        )
      } else {
        list(
          status = 404L,
          headers = list(
            "Content-Type" = "text/plain",
            "X-Content-Type-Options" = "nosniff"
          ),
          body = "404 Not Found"
        )
      }
    }
  )

  # Start server (blocks execution)
  httpuv::runServer(host = host, port = port, app = app)
}
