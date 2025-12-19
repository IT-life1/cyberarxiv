#' Render and serve the cyberarxiv dashboard using httpuv
#'
#' @inheritParams render_dashboard
#' @param host Host address to listen on (default is "0.0.0.0").
#' @param port Port to listen on (default is 8000).
#' @return Invisibly returns the server object (the function blocks execution).
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

  app <- list(
    call = function(req) {
      path <- req$PATH_INFO
      
      if (path == "" || path == "/") {
        path <- "/dashboard.html"
      }
      
      normalized_path <- sub("^/", "", path)
      normalized_path <- gsub("/\\.\\./", "/", normalized_path)  # Убираем ../
      normalized_path <- gsub("^\\.\\./", "", normalized_path)     # Убираем ../ в начале
      
      file_path <- file.path(output_path, normalized_path)
      
      file_path <- normalizePath(file_path, winslash = "/", mustWork = FALSE)
      if (!startsWith(file_path, output_path)) {
        return(list(
          status = 403L,
          headers = list("Content-Type" = "text/plain"),
          body = "403 Forbidden"
        ))
      }
      
      if (file.exists(file_path) && !dir.exists(file_path)) {
        ext <- tools::file_ext(file_path)
        content_type <- switch(
          ext,
          html = "text/html",
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
        
        body <- readBin(file_path, "raw", file.info(file_path)$size)
        
        list(
          status = 200L,
          headers = list("Content-Type" = content_type),
          body = body
        )
      } else {
        list(
          status = 404L,
          headers = list("Content-Type" = "text/plain"),
          body = "404 Not Found"
        )
      }
    }
  )

  httpuv::runServer(host = host, port = port, app = app)
}