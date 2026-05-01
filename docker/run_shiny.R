#!/usr/bin/env Rscript
# Запуск Shiny GUI внутри Docker-контейнера.
# Используется, если в docker-compose.yml задан command: Rscript docker/run_shiny.R

log <- function(...) cat(sprintf("[%s] ", Sys.time()), ..., "\n", file = stderr())

port <- as.integer(Sys.getenv("SHINY_PORT", "3838"))
ml_url <- Sys.getenv("ML_SERVICE_URL", "http://cyberarxiv-ml:5001")

if (!requireNamespace("cyberarxiv", quietly = TRUE)) {
  stop("Package cyberarxiv не установлен. Проверь Dockerfile.")
}
for (pkg in c("shiny", "DT")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop("Package ", pkg, " нужен для GUI. Добавь в Dockerfile: ",
         "R -e 'install.packages(\"", pkg, "\")'")
  }
}

log("Starting Shiny GUI on port", port, "- ML service:", ml_url)

cyberarxiv::launch_app(
  host = "0.0.0.0",
  port = port,
  ml_service_url = ml_url,
  launch_browser = FALSE
)
