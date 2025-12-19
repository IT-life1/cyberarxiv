#' Render and serve the cyberarxiv dashboard via nginx
#'
#' Рендерит дашборд (по умолчанию во `/var/www/html`) и запускает `nginx`
#' в режиме `daemon off;`, чтобы отдавать статические файлы. Функция блокирует
#' выполнение, пока веб-сервер работает.
#'
#' @inheritParams render_dashboard
#' @param nginx_exec Полный путь к бинарю `nginx`. По умолчанию используется
#'   `Sys.which("nginx")`.
#' @param nginx_args Вектор аргументов командной строки, передаваемых в `nginx`.
#'   По умолчанию — `c("-g", "daemon off;")`, чтобы сервер работал на переднем
#'   плане.
#' @return Невидимо возвращает код завершения процесса `nginx`.
#' @export
serve_dashboard <- function(source = NULL,
                            output_dir = "/var/www/html",
                            quiet = TRUE,
                            nginx_exec = Sys.which("nginx"),
                            nginx_args = c("-g", "daemon off;"),
                            ...) {
  if (!nzchar(nginx_exec)) {
    stop("nginx executable not found on PATH; install nginx or set `nginx_exec` explicitly.")
  }

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  render_dashboard(
    source = source,
    output_dir = output_dir,
    quiet = quiet,
    ...
  )

  message(
    "Dashboard rendered to ",
    normalizePath(output_dir, winslash = "/", mustWork = TRUE)
  )
  message("Starting nginx server (", nginx_exec, ") ...")

  status <- system2(nginx_exec, nginx_args)
  invisible(status)
}
