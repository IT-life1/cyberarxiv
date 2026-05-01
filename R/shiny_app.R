#' CyberArXiv Shiny GUI
#'
#' @param host Host (default "0.0.0.0").
#' @param port Port (default 3838).
#' @param ml_service_url URL ML-сервиса.
#' @param launch_browser Открывать браузер.
#' @export
launch_app <- function(host = "0.0.0.0",
                       port = 3838,
                       ml_service_url = NULL,
                       launch_browser = interactive()) {

  need <- c("shiny", "DT", "plotly", "dplyr", "tibble", "lubridate", "stringr",
            "rhandsontable", "httr2")
  missing_pkgs <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing_pkgs))
    stop("Нужны пакеты: ", paste(missing_pkgs, collapse = ", "), call. = FALSE)

  if (is.null(ml_service_url))
    ml_service_url <- Sys.getenv("ML_SERVICE_URL", "http://localhost:5001")

  # Load task definitions statically (no ML service call) for UI construction
  init_tasks   <- tryCatch(load_ml_tasks(), error = function(e) list(
    default = list(label = "Общая классификация", models = list(en = "best_model"))
  ))
  init_choices <- setNames(names(init_tasks),
                           vapply(init_tasks, `[[`, character(1), "label"))

  ui     <- .build_ui(init_choices)
  server <- .build_server(ml_service_url, init_tasks, init_choices)

  message("CyberArXiv GUI: http://", host, ":", port)
  shiny::runApp(shiny::shinyApp(ui = ui, server = server),
                host = host, port = port, launch.browser = launch_browser)
}

# ============================================================
#  UI
# ============================================================

#' @noRd
.build_ui <- function(ml_task_choices = c("Общая классификация" = "default")) {
  shiny::fluidPage(
    title = "CyberArXiv — GUI",
    shiny::tags$head(shiny::tags$style(shiny::HTML("
      body { background: #f7f7fa; }
      .header-bar {
        background: linear-gradient(90deg, #1e3a5f 0%, #2c5282 100%);
        color: white; padding: 16px 24px; margin-bottom: 18px;
        border-radius: 0 0 6px 6px; box-shadow: 0 2px 6px rgba(0,0,0,0.08);
      }
      .header-bar h1 { margin: 0; font-size: 22px; font-weight: 600; }
      .header-bar .subtitle { font-size: 13px; opacity: 0.85; margin-top: 4px; }
      .status-ok   { color: #2e7d32; font-weight: 600; }
      .status-fail { color: #c62828; font-weight: 600; }
      .status-idle { color: #757575; }
      .metric-box {
        background: white; padding: 16px; border-radius: 6px;
        border-left: 4px solid #2c5282; margin-bottom: 12px;
        box-shadow: 0 1px 3px rgba(0,0,0,0.06);
      }
      .metric-box .metric-label { font-size: 12px; color: #666; text-transform: uppercase; }
      .metric-box .metric-value { font-size: 26px; font-weight: 700; color: #1e3a5f; }
      .log-area {
        background: #1e1e1e; color: #d4d4d4; padding: 12px;
        font-family: 'Courier New', monospace; font-size: 12px;
        border-radius: 4px; max-height: 320px; overflow-y: auto; white-space: pre-wrap;
      }
    "))),

    shiny::div(class = "header-bar",
      shiny::h1("CyberArXiv — сбор и классификация статей"),
      shiny::div(class = "subtitle",
        "Multi-source ETL · DuckDB · Keyword + ML classifier store")
    ),

    shiny::tabsetPanel(id = "main_tabs", type = "tabs",

      # ---- 1. Обзор ----
      shiny::tabPanel(title = "\U0001F4CA Обзор",
        shiny::br(),
        shiny::fluidRow(
          shiny::column(3, shiny::div(class = "metric-box",
            shiny::div(class = "metric-label", "Всего статей"),
            shiny::div(class = "metric-value", shiny::textOutput("m_total", inline = TRUE))
          )),
          shiny::column(3, shiny::div(class = "metric-box",
            shiny::div(class = "metric-label", "С ML-меткой"),
            shiny::div(class = "metric-value", shiny::textOutput("m_ml", inline = TRUE))
          )),
          shiny::column(3, shiny::div(class = "metric-box",
            shiny::div(class = "metric-label", "Источников"),
            shiny::div(class = "metric-value", shiny::textOutput("m_sources", inline = TRUE))
          )),
          shiny::column(3, shiny::div(class = "metric-box",
            shiny::div(class = "metric-label", "ML-сервис"),
            shiny::div(class = "metric-value", shiny::uiOutput("m_ml_status"))
          ))
        ),
        shiny::br(),
        shiny::fluidRow(
          shiny::column(4,
            shiny::h4("По источникам"),
            plotly::plotlyOutput("plot_sources", height = "300px")
          ),
          shiny::column(4,
            shiny::h4("По тегам (keyword)"),
            plotly::plotlyOutput("plot_tags", height = "300px")
          ),
          shiny::column(4,
            shiny::h4("Публикации по месяцам"),
            plotly::plotlyOutput("plot_month", height = "300px")
          )
        ),
        shiny::br(),
        shiny::actionButton("btn_refresh_overview", "\U0001F504 Обновить", class = "btn-primary")
      ),

      # ---- 2. Загрузка (ETL) ----
      shiny::tabPanel(title = "\U0001F4E5 Загрузка (ETL)",
        shiny::br(),
        shiny::fluidRow(
          shiny::column(4,
            shiny::h4("Параметры"),
            shiny::numericInput("etl_max_results", "Статей на источник:",
              value = 50, min = 10, max = 2000, step = 10),
            shiny::checkboxInput("etl_only_new",
              "Только новые (not in DB)", value = FALSE),
            shiny::uiOutput("ui_etl_collector_params"),
            shiny::hr(),
            shiny::h5("Коллекторы"),
            shiny::uiOutput("ui_etl_sources"),
            shiny::hr(),
            shiny::checkboxInput("etl_with_ml",
              "ML-классификация после ETL", value = TRUE),
            shiny::uiOutput("ui_etl_lang_routing"),
            shiny::br(),
            shiny::actionButton("btn_run_etl", "▶ Запустить ETL",
                                class = "btn-success btn-lg"),
            shiny::br(), shiny::br(),
            shiny::uiOutput("etl_status")
          ),
          shiny::column(8,
            shiny::h4("Лог выполнения"),
            shiny::div(class = "log-area", shiny::verbatimTextOutput("etl_log")),
            shiny::br(),
            shiny::h4("Последние загруженные"),
            DT::DTOutput("etl_result_table")
          )
        )
      ),

      # ---- 3. Таблица статей ----
      shiny::tabPanel(title = "\U0001F4DA Таблица статей",
        shiny::br(),
        shiny::fluidRow(
          shiny::column(3,
            shiny::textInput("tbl_search", "\U0001F50D Поиск (title/abstract):", "")
          ),
          shiny::column(2,
            shiny::selectInput("tbl_year", "Год:", choices = c("Все" = ""), selected = "")
          ),
          shiny::column(2,
            shiny::selectInput("tbl_source", "Источник:",
                               choices = c("Все" = ""), selected = "")
          ),
          shiny::column(2,
            shiny::selectInput("tbl_tag", "Тег (keyword):",
                               choices = c("Все" = ""), selected = "")
          ),
          shiny::column(1,
            shiny::selectInput("tbl_lang", "Язык:",
                               choices = c("Все" = ""), selected = "")
          ),
          shiny::column(2,
            shiny::selectInput("tbl_ml_task", "ML-задача:",
                               choices = c("(нет)" = ""), selected = "")
          )
        ),
        shiny::fluidRow(
          shiny::column(10),
          shiny::column(2,
            shiny::actionButton("btn_tbl_refresh", "\U0001F504", class = "btn-info"),
            shiny::downloadButton("btn_tbl_export", "CSV")
          )
        ),
        shiny::br(),
        shiny::textOutput("tbl_count"),
        shiny::br(),
        DT::DTOutput("tbl_main")
      ),

      # ---- 4. ML-классификатор ----
      shiny::tabPanel(title = "\U0001F916 ML-классификатор",
        shiny::br(),
        shiny::fluidRow(
          shiny::column(6,
            shiny::h4("Статус сервиса"),
            shiny::actionButton("btn_ml_check", "Обновить статус", class = "btn-primary"),
            shiny::br(), shiny::br(),
            shiny::verbatimTextOutput("ml_info"),
            shiny::br(),
            shiny::h4("Пакетная классификация"),
            shiny::selectInput("ml_task_batch", "Задача:",
                               choices = ml_task_choices, selected = names(ml_task_choices)[1]),
            shiny::uiOutput("ml_task_col_info"),
            shiny::helpText(
              "Только новые — статьи без результата для выбранной задачи.",
              "Все (перезаписать) — прогонит заново всё, перезапишет существующие результаты."
            ),
            shiny::actionButton("btn_ml_run", "▶ Только новые", class = "btn-success"),
            shiny::actionButton("btn_ml_run_all", "\U0001F501 Все (перезаписать)",
                                class = "btn-warning"),
            shiny::br(), shiny::br(),
            shiny::uiOutput("ml_batch_progress"),
            shiny::verbatimTextOutput("ml_batch_status")
          ),
          shiny::column(6,
            shiny::h4("Ad-hoc: одна аннотация"),
            shiny::selectInput("ml_task_adhoc", "Задача:",
                               choices = ml_task_choices, selected = names(ml_task_choices)[1]),
            shiny::selectInput("ml_adhoc_lang", "Язык текста:",
                               choices = c("Английский" = "en", "Русский" = "ru"), selected = "en"),
            shiny::textAreaInput("adhoc_text", "Abstract:", rows = 7, width = "100%",
              value = paste0("We present a novel approach to intrusion detection ",
                             "using deep learning combined with attention mechanisms ",
                             "to identify network anomalies in real-time.")),
            shiny::actionButton("btn_adhoc", "Классифицировать", class = "btn-primary"),
            shiny::br(), shiny::br(),
            shiny::uiOutput("adhoc_result")
          )
        )
      ),

      # ---- 5. Аналитика ----
      shiny::tabPanel(title = "\U0001F4C8 Аналитика",
        shiny::br(),
        # Фильтр ML-задачи — влияет на confidence, сравнение и cross-tab
        shiny::fluidRow(
          shiny::column(3,
            shiny::selectInput("analytics_ml_task", "ML-задача для анализа:",
                               choices = c("(нет данных)" = ""), selected = "")
          )
        ),
        shiny::br(),
        # Ряд 1: авторы + источники
        shiny::fluidRow(
          shiny::column(6,
            shiny::h4("Топ авторов"),
            plotly::plotlyOutput("plot_authors", height = "340px")
          ),
          shiny::column(6,
            shiny::h4("По источникам"),
            plotly::plotlyOutput("plot_sources_analytics", height = "340px")
          )
        ),
        shiny::br(),
        # Ряд 2: слова + публикации по годам
        shiny::fluidRow(
          shiny::column(6,
            shiny::h4("Самые частые слова"),
            plotly::plotlyOutput("plot_words", height = "340px")
          ),
          shiny::column(6,
            shiny::h4("Публикации по годам"),
            plotly::plotlyOutput("plot_by_year", height = "340px")
          )
        ),
        shiny::br(),
        # Ряд 3: confidence histogram + avg confidence по тегу + охват ML
        shiny::fluidRow(
          shiny::column(4,
            shiny::h4("Уверенность ML-модели"),
            plotly::plotlyOutput("plot_ml_conf", height = "280px")
          ),
          shiny::column(4,
            shiny::h4("Средний confidence по тегу"),
            plotly::plotlyOutput("plot_conf_by_tag", height = "280px")
          ),
          shiny::column(4,
            shiny::h4("Охват ML-классификации"),
            plotly::plotlyOutput("plot_ml_coverage", height = "280px")
          )
        ),
        shiny::br(),
        # Ряд 4: keyword vs ML
        shiny::fluidRow(
          shiny::column(12,
            shiny::h4("Сравнение: Keyword vs ML классификация"),
            plotly::plotlyOutput("plot_tag_comparison", height = "320px")
          )
        ),
        shiny::br(),
        # Ряд 5: cross-tab
        shiny::fluidRow(
          shiny::column(12,
            shiny::h4("Перекрёстная таблица: Keyword-тег / ML-тег"),
            DT::DTOutput("cross_tab")
          )
        )
      ),

      # ---- 6. Обучение модели ----
      shiny::tabPanel(title = "\U0001F393 Обучение модели",
        shiny::br(),
        shiny::tabsetPanel(id = "tr_subtabs", type = "pills",

          # ---------- 6.1 Конфигурация ----------
          shiny::tabPanel("\U0001F4DD Конфигурация",
            shiny::br(),
            shiny::fluidRow(
              shiny::column(6,
                shiny::h4("Классы (таксономия)"),
                shiny::helpText("Эти классы передаются LLM в промпте. Можно редактировать прямо в таблице, добавлять и удалять. Имя в snake_case."),
                rhandsontable::rHandsontableOutput("tr_classes_table", height = "320px"),
                shiny::br(),
                shiny::actionButton("btn_tr_class_add", "➕ Добавить класс", class = "btn-default"),
                shiny::actionButton("btn_tr_class_save", "💾 Сохранить классы", class = "btn-success"),
                shiny::br(), shiny::br(),
                shiny::verbatimTextOutput("tr_classes_status")
              ),
              shiny::column(6,
                shiny::h4("Системный промпт LLM"),
                shiny::textAreaInput("tr_system_prompt", NULL, rows = 7, width = "100%",
                                     value = ""),
                shiny::h4("Пользовательский шаблон промпта"),
                shiny::helpText("Доступные плейсхолдеры: {title}, {abstract}, {classes_list}, {classes}"),
                shiny::textAreaInput("tr_user_template", NULL, rows = 6, width = "100%",
                                     value = ""),
                shiny::actionButton("btn_tr_prompts_save", "💾 Сохранить промпты",
                                    class = "btn-success"),
                shiny::br(), shiny::br(),
                shiny::verbatimTextOutput("tr_prompts_status")
              )
            ),
            shiny::br(),
            shiny::h4("Настройки LLM-провайдера"),
            shiny::fluidRow(
              shiny::column(3,
                shiny::selectInput("tr_llm_provider", "Провайдер:",
                                   choices = c("OpenAI" = "openai",
                                               "Anthropic (Claude)" = "anthropic",
                                               "xAI Grok" = "grok"),
                                   selected = "openai"),
                shiny::textInput("tr_llm_model", "Модель:", value = "gpt-4o-mini",
                                 placeholder = "gpt-4o-mini / claude-sonnet-4-6 / grok-4")
              ),
              shiny::column(3,
                shiny::passwordInput("tr_llm_api_key", "API key:",
                                     value = "", placeholder = "оставьте пустым, чтобы не менять"),
                shiny::textInput("tr_llm_base_url", "base_url (опционально):",
                                 value = "", placeholder = "напр. https://api.deepseek.com/v1")
              ),
              shiny::column(3,
                shiny::numericInput("tr_llm_temp", "temperature:", value = 0,
                                    min = 0, max = 2, step = 0.1),
                shiny::numericInput("tr_llm_max_tokens", "max_tokens:", value = 32,
                                    min = 8, max = 1024)
              ),
              shiny::column(3,
                shiny::numericInput("tr_llm_concurrency", "concurrency:", value = 4,
                                    min = 1, max = 32),
                shiny::numericInput("tr_llm_timeout", "timeout, сек:", value = 60,
                                    min = 5, max = 600)
              )
            ),
            shiny::actionButton("btn_tr_llm_save", "💾 Сохранить LLM",
                                class = "btn-success"),
            shiny::actionButton("btn_tr_health", "\U0001F50C Проверить подключение",
                                class = "btn-info"),
            shiny::br(), shiny::br(),
            shiny::verbatimTextOutput("tr_llm_status"),
            shiny::verbatimTextOutput("tr_health_info")
          ),

          # ---------- 6.2 Сбор данных ----------
          shiny::tabPanel("\U0001F4E5 Сбор данных",
            shiny::br(),
            shiny::fluidRow(
              shiny::column(4,
                shiny::h4("Параметры"),
                shiny::selectInput("tr_collect_target", "Сколько статей собрать:",
                                   choices = c("1 000"  = 1000,
                                               "5 000"  = 5000,
                                               "10 000" = 10000,
                                               "20 000" = 20000,
                                               "50 000" = 50000,
                                               "70 000" = 70000,
                                               "100 000" = 100000),
                                   selected = 10000),
                shiny::textInput("tr_collect_query",
                                 "arXiv search_query (пусто = по умолчанию):",
                                 value = ""),
                shiny::numericInput("tr_collect_page_size", "page_size:",
                                    value = 200, min = 50, max = 2000, step = 50),
                shiny::actionButton("btn_tr_collect", "▶ Старт сбора",
                                    class = "btn-success btn-lg"),
                shiny::br(), shiny::br(),
                shiny::verbatimTextOutput("tr_collect_status"),
                shiny::uiOutput("tr_collect_progress")
