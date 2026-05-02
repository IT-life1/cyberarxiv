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
              ),
              shiny::column(8,
                shiny::h4("Лог"),
                shiny::div(class = "log-area", shiny::verbatimTextOutput("tr_collect_log")),
                shiny::br(),
                shiny::h4("Сохранённые сырые выборки"),
                shiny::actionButton("btn_tr_files_raw_refresh", "\U0001F504",
                                    class = "btn-info btn-sm"),
                DT::DTOutput("tr_files_raw")
              )
            )
          ),

          # ---------- 6.3 Разметка LLM ----------
          shiny::tabPanel("\U0001F916 Разметка LLM",
            shiny::br(),
            shiny::fluidRow(
              shiny::column(4,
                shiny::h4("Параметры"),
                shiny::uiOutput("ui_tr_label_raw_pick"),
                shiny::numericInput("tr_label_max_rows",
                                    "Сколько строк размечать (0 = все):",
                                    value = 0, min = 0, max = 1000000, step = 100),
                shiny::actionButton("btn_tr_label", "▶ Запустить LLM",
                                    class = "btn-success btn-lg"),
                shiny::actionButton("btn_tr_label_cancel", "⏹ Отмена",
                                    class = "btn-warning"),
                shiny::br(), shiny::br(),
                shiny::verbatimTextOutput("tr_label_status"),
                shiny::uiOutput("tr_label_progress")
              ),
              shiny::column(8,
                shiny::h4("Лог разметки"),
                shiny::div(class = "log-area", shiny::verbatimTextOutput("tr_label_log")),
                shiny::br(),
                shiny::h4("Размеченные выборки"),
                shiny::actionButton("btn_tr_files_labeled_refresh", "\U0001F504",
                                    class = "btn-info btn-sm"),
                DT::DTOutput("tr_files_labeled")
              )
            )
          ),

          # ---------- 6.4 Excel ----------
          shiny::tabPanel("\U0001F4D2 Excel",
            shiny::br(),
            shiny::fluidRow(
              shiny::column(4,
                shiny::h4("Экспорт в Excel"),
                shiny::uiOutput("ui_tr_excel_labeled_pick"),
                shiny::numericInput("tr_excel_max_rows",
                                    "Макс. строк в Excel (0 = все):",
                                    value = 0, min = 0, max = 1000000, step = 1000),
                shiny::actionButton("btn_tr_export_excel", "▶ Экспорт",
                                    class = "btn-success"),
                shiny::br(), shiny::br(),
                shiny::verbatimTextOutput("tr_excel_status")
              ),
              shiny::column(8,
                shiny::h4("Готовые .xlsx"),
                shiny::actionButton("btn_tr_files_excel_refresh", "\U0001F504",
                                    class = "btn-info btn-sm"),
                DT::DTOutput("tr_files_excel"),
                shiny::helpText(
                  "Файлы лежат в training_data/excel/. ",
                  "Можно отредактировать вручную (исправить метки) и подать на обучение."
                )
              )
            )
          ),

          # ---------- 6.5 Обучение ----------
          shiny::tabPanel("\U0001F525 Обучение",
            shiny::br(),
            shiny::fluidRow(
              shiny::column(4,
                shiny::h4("Гиперпараметры"),
                shiny::uiOutput("ui_tr_train_excel_pick"),
                shiny::textInput("tr_train_model_name",
                                 "Имя выходной модели (без .pt):",
                                 value = "custom_model"),
                shiny::textInput("tr_train_base_model",
                                 "Базовая HuggingFace-модель:",
                                 value = "distilbert-base-uncased"),
                shiny::numericInput("tr_train_epochs", "epochs:", value = 8,
                                    min = 1, max = 200, step = 1),
                shiny::numericInput("tr_train_batch_size", "batch_size:", value = 16,
                                    min = 1, max = 256, step = 1),
                shiny::numericInput("tr_train_lr", "learning rate:", value = 2e-5,
                                    min = 1e-7, max = 1, step = 1e-6),
                shiny::numericInput("tr_train_max_length", "max_length:", value = 256,
                                    min = 32, max = 1024, step = 32),
                shiny::numericInput("tr_train_test_size", "test_size:", value = 0.1,
                                    min = 0.01, max = 0.4, step = 0.01),
                shiny::numericInput("tr_train_val_size", "val_size:", value = 0.1,
                                    min = 0.01, max = 0.4, step = 0.01),
                shiny::textInput("tr_train_mlflow_uri", "MLflow tracking URI:",
                                 value = Sys.getenv("MLFLOW_TRACKING_URI",
                                                    "http://localhost:5000"),
                                 placeholder = "http://localhost:5000"),
                shiny::helpText(
                  "Подсказка: train_test_split дропает классы, в которых меньше",
                  " ceil(1/(test+val)) + 1 примеров. Дефолт 0.1+0.1 → нужно ≥ 6 ",
                  "статей на класс. Для маленьких выборок понизьте обе доли ",
                  "(0.05+0.05 → ≥ 11 на класс не нужно)."),
                shiny::actionButton("btn_tr_train", "▶ Старт обучения",
                                    class = "btn-success btn-lg"),
                shiny::actionButton("btn_tr_train_cancel", "⏹ Отмена",
                                    class = "btn-warning"),
                shiny::br(), shiny::br(),
                shiny::verbatimTextOutput("tr_train_status"),
                shiny::uiOutput("tr_train_progress")
              ),
              shiny::column(8,
                shiny::h4("Лог обучения"),
                shiny::div(class = "log-area", shiny::verbatimTextOutput("tr_train_log")),
                shiny::br(),
                shiny::h4("MLflow"),
                shiny::uiOutput("tr_mlflow_link"),
                shiny::br(),
                shiny::actionButton("btn_tr_reload_models", "\U0001F501 Reload models",
                                    class = "btn-primary"),
                shiny::helpText("Обновляет список моделей в инференс-сервисе после обучения."),
                shiny::br(),
                shiny::verbatimTextOutput("tr_reload_status"),
                shiny::hr(),
                shiny::h4("Зарегистрировать как ML-задачу"),
                shiny::helpText(
                  "Добавляет обученную модель в дропдауны \U201CЗадача\U201D на ",
                  "вкладках ML-классификатор и ETL. Имя модели берётся из ",
                  "«", "Имя выходной модели", "» выше."),
                shiny::textInput("tr_register_task_name",
                                 "Идентификатор задачи (snake_case):",
                                 value = "", placeholder = "my_grok_task"),
                shiny::textInput("tr_register_task_label",
                                 "Отображаемое название:",
                                 value = "", placeholder = "Моя модель (Grok)"),
                shiny::selectInput("tr_register_task_lang",
                                   "Язык:",
                                   choices = c("Английский" = "en",
                                               "Русский" = "ru"),
                                   selected = "en"),
                shiny::actionButton("btn_tr_register_task",
                                    "\U0001F4DD Зарегистрировать",
                                    class = "btn-primary"),
                shiny::br(), shiny::br(),
                shiny::verbatimTextOutput("tr_register_status")
              )
            )
          ),

          # ---------- 6.6 Все джобы ----------
          shiny::tabPanel("\U0001F4DC Джобы",
            shiny::br(),
            shiny::actionButton("btn_tr_jobs_refresh", "\U0001F504 Обновить",
                                class = "btn-info"),
            shiny::br(), shiny::br(),
            DT::DTOutput("tr_jobs_table"),
            shiny::br(),
            shiny::h4("Лог выбранного джоба"),
            shiny::helpText("Нажмите на строку таблицы, чтобы увидеть полный лог."),
            shiny::div(class = "log-area", shiny::verbatimTextOutput("tr_job_log_detail"))
          )
        )
      ),

      # ---- 7. Настройки ----
      shiny::tabPanel(title = "⚙ Настройки",
        shiny::br(),
        shiny::h4("Окружение"),
        shiny::verbatimTextOutput("settings_info"),
        shiny::br(),
        shiny::h4("Действия"),
        shiny::actionButton("btn_reinit_db", "⚠ Переинициализировать схему БД",
                            class = "btn-warning"),
        shiny::helpText("Создаст таблицы и добавит недостающие колонки. Данные не удалит."),
        shiny::br(), shiny::br(),
        shiny::verbatimTextOutput("settings_log"),
        shiny::hr(),
        shiny::h4("Удаление статей"),
        shiny::fluidRow(
          shiny::column(4,
            shiny::selectizeInput("del_tags", "По keyword-тегу:",
                                  choices = c(), multiple = TRUE,
                                  options = list(placeholder = "выберите один или несколько"))
          ),
          shiny::column(3,
            shiny::selectInput("del_source", "По источнику:",
                               choices = c("Все источники" = ""), selected = "")
          ),
          shiny::column(2,
            shiny::br(),
            shiny::actionButton("btn_delete_articles", "\U26A0 Удалить",
                                class = "btn-danger")
          ),
          shiny::column(3,
            shiny::br(),
            shiny::textOutput("del_preview")
          )
        ),
        shiny::verbatimTextOutput("del_status")
      )
    )
  )
}

# ============================================================
#  SERVER
# ============================================================

#' @noRd
.build_server <- function(ml_service_url, init_tasks = NULL, init_choices = NULL) {
  function(input, output, session) {

    publications      <- shiny::reactiveVal(NULL)
    etl_log_text      <- shiny::reactiveVal("")
    ml_log_text       <- shiny::reactiveVal("")
    settings_log_text <- shiny::reactiveVal("")

    # Загрузить доступные коллекторы
    collectors_df <- tryCatch(list_collectors(), error = function(e) NULL)
    collector_choices <- if (!is.null(collectors_df) && nrow(collectors_df) > 0) {
      setNames(collectors_df$name, paste0(collectors_df$label, " [", collectors_df$type, "]"))
    } else {
      character(0)
    }
    enabled_collectors <- if (!is.null(collectors_df))
      collectors_df$name[collectors_df$enabled] else character(0)

    # ML-задачи: начинаем со статических (переданных из launch_app), затем обогащаем
    # доступностью моделей из сервиса (может быть недоступен при старте)
    ml_tasks_info   <- init_tasks  %||% load_ml_tasks()
    ml_task_choices <- init_choices %||% setNames(names(ml_tasks_info),
                                                  vapply(ml_tasks_info, `[[`, character(1), "label"))

    # ---- Динамические UI-элементы ----
    output$ui_etl_sources <- shiny::renderUI({
      if (length(collector_choices) == 0) {
        shiny::helpText("Коллекторы не найдены.")
      } else {
        shiny::checkboxGroupInput("etl_sources", NULL,
          choices  = collector_choices,
          selected = enabled_collectors)
      }
    })

    output$ui_etl_lang_routing <- shiny::renderUI({
      if (!isTRUE(input$etl_with_ml)) return(NULL)
      shiny::div(
        style = paste0("background:white; border-left:3px solid #2c5282; ",
                       "border-radius:4px; padding:10px 14px; margin-bottom:8px; ",
                       "box-shadow:0 1px 3px rgba(0,0,0,0.06);"),
        shiny::div(
          style = "font-size:11px; color:#888; text-transform:uppercase; letter-spacing:.05em; margin-bottom:8px;",
          "\U1F916 Задача ML"
        ),
        shiny::selectInput("etl_ml_task", NULL,
                           choices = ml_task_choices, selected = names(ml_task_choices)[1],
                           width = "100%"),
        shiny::uiOutput("ui_etl_task_hint")
      )
    })

    output$ui_etl_task_hint <- shiny::renderUI({
      task_id <- input$etl_ml_task %||% names(ml_task_choices)[1]
      task    <- ml_tasks_info[[task_id]]
      if (is.null(task)) return(NULL)
      avail   <- task$available_models %||% list()
      all_m   <- task$models %||% list()
      lines <- lapply(names(all_m), function(lang) {
        m    <- all_m[[lang]]
        ok   <- lang %in% names(avail)
        icon <- if (ok) "✓" else "–"
        col  <- if (ok) "#276749" else "#999"
        shiny::div(style = paste0("font-size:12px; color:", col, ";"),
                   paste0(icon, " ", lang, " → ", m,
                          if (!ok) " (не загружена)" else ""))
      })
      shiny::tagList(lines)
    })

    output$ui_etl_collector_params <- shiny::renderUI({
      sel <- if (length(input$etl_sources) > 0) input$etl_sources else enabled_collectors
      if (length(sel) == 0 || is.null(collectors_df) || nrow(collectors_df) == 0)
        return(NULL)

      active_df <- collectors_df[collectors_df$name %in% sel, ]
      searchable_types <- c("atom", "core_api", "oai_pmh", "rss")
      configurable <- active_df[active_df$type %in% searchable_types, ]
      if (nrow(configurable) == 0) return(NULL)

      hint <- list(
        atom     = "cat:cs.CR AND all:ransomware",
        core_api = "cybersecurity OR malware OR phishing",
        oai_pmh  = "from: YYYY-MM-DD",
        rss      = ""
      )

      card_style <- paste0(
        "background:white; border-left:2px solid #4a90d9; ",
        "border-radius:3px; padding:5px 8px; margin-bottom:5px; ",
        "box-shadow:0 1px 2px rgba(0,0,0,0.05);"
      )
      label_style <- "font-size:10px; color:#888; text-transform:uppercase; letter-spacing:.04em; margin-bottom:2px;"

      cards <- lapply(seq_len(nrow(configurable)), function(i) {
        nm  <- configurable$name[i]
        typ <- configurable$type[i]
        lbl <- configurable$label[i]

        input_el <- if (typ == "oai_pmh") {
          shiny::textInput(paste0("cq_", nm), NULL, value = "",
                           placeholder = "2024-01-01", width = "100%")
        } else {
          shiny::textInput(paste0("cq_", nm), NULL, value = "",
                           placeholder = hint[[typ]] %||% "", width = "100%")
        }

        shiny::div(style = card_style,
          shiny::div(style = label_style, lbl),
          input_el
        )
      })

      shiny::tagList(
        shiny::div(style = "font-size:12px; font-weight:600; color:#1e3a5f; margin-bottom:4px;",
                   "\U1F50D Запросы (пусто = по умолчанию):"),
        shiny::tagList(cards)
      )
    })

    shiny::updateSelectInput(session, "ml_task_batch", choices = ml_task_choices)
    shiny::updateSelectInput(session, "ml_task_adhoc", choices = ml_task_choices)

    # ---- Загрузка из БД ----
    reload_publications <- function() {
      res <- tryCatch(load_publications(), error = function(e) {
        shiny::showNotification(paste("Ошибка БД:", conditionMessage(e)),
                                type = "error", duration = 8)
        NULL
      })
      publications(res)
    }
    reload_publications()

    # ---- Обзор ----
    output$m_total <- shiny::renderText({
      df <- publications(); if (is.null(df)) "—" else format(nrow(df), big.mark = " ")
    })
    output$m_ml <- shiny::renderText({
      df <- publications()
      if (is.null(df) || nrow(df) == 0) return("—")
      if (!"ml_results" %in% names(df)) return("—")
      n <- sum(!is.na(df$ml_results) & nzchar(df$ml_results))
      format(n, big.mark = " ")
    })
    output$m_sources <- shiny::renderText({
      df <- publications()
      if (is.null(df) || !"source" %in% names(df)) "—"
      else as.character(length(unique(df$source[!is.na(df$source)])))
    })
    output$m_ml_status <- shiny::renderUI({
      input$btn_refresh_overview
      shiny::invalidateLater(30000)
      ok <- tryCatch(ml_service_is_healthy(ml_service_url), error = function(e) FALSE)
      if (isTRUE(ok))
        shiny::span(class = "status-ok",  "✓ OK",  style = "font-size:18px;")
      else
        shiny::span(class = "status-fail", "✗ OFF", style = "font-size:18px;")
    })

    output$plot_sources <- plotly::renderPlotly({
      df <- publications()
      if (is.null(df) || nrow(df) == 0 || !"source" %in% names(df))
        return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      cnts <- dplyr::count(df, source, sort = TRUE)
      plotly::plot_ly(cnts, x = ~reorder(source, n), y = ~n, type = "bar",
                      marker = list(color = "#2c5282")) |>
        plotly::layout(xaxis = list(tickangle = -30, title = ""),
                       yaxis = list(title = "Статей"),
                       margin = list(b = 80))
    })
    output$plot_tags <- plotly::renderPlotly({
      df <- publications()
      if (is.null(df) || nrow(df) == 0 || !"tag" %in% names(df))
        return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      cnts <- dplyr::count(df, tag, sort = TRUE) |> head(20)
      plotly::plot_ly(cnts, x = ~reorder(tag, n), y = ~n, type = "bar",
                      marker = list(color = "#e6550d")) |>
        plotly::layout(xaxis = list(tickangle = -45, title = ""),
                       yaxis = list(title = "Статей"),
                       margin = list(b = 110))
    })
    output$plot_month <- plotly::renderPlotly({
      df <- publications()
      if (is.null(df) || nrow(df) == 0 || !"published_date" %in% names(df))
        return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      df2 <- df |>
        dplyr::mutate(month = lubridate::floor_date(as.POSIXct(published_date), "month")) |>
        dplyr::filter(!is.na(month)) |>
        dplyr::count(month) |>
        dplyr::arrange(month)
      plotly::plot_ly(df2, x = ~month, y = ~n, type = "scatter", mode = "lines+markers",
                      line = list(color = "#2c5282", width = 2)) |>
        plotly::layout(xaxis = list(title = "Месяц"), yaxis = list(title = "Кол-во"))
    })
    shiny::observeEvent(input$btn_refresh_overview, {
      reload_publications()
      shiny::showNotification("Обновлено", type = "message", duration = 2)
    })

    # ---- ETL ----
    shiny::observeEvent(input$btn_run_etl, {
      n_req    <- as.integer(input$etl_max_results)
      only_new <- isTRUE(input$etl_only_new)
      use_ml   <- isTRUE(input$etl_with_ml)
      sel_src  <- input$etl_sources
      sources  <- if (length(sel_src) > 0) sel_src else NULL

      # Языковой маппинг берём из выбранной задачи
      task_id         <- trimws(input$etl_ml_task %||% names(ml_task_choices)[1])
      language_models <- (ml_tasks_info[[task_id]]$models) %||% list(en = "best_model")

      # Per-collector query overrides
      active_names    <- if (!is.null(sources)) sources else enabled_collectors
      param_overrides <- list()
      if (!is.null(collectors_df)) {
        for (nm in active_names) {
          row   <- collectors_df[collectors_df$name == nm, ]
          if (nrow(row) == 0) next
          q_val <- trimws(input[[paste0("cq_", nm)]] %||% "")
          if (!nzchar(q_val)) next
          param_overrides[[nm]] <- if (row$type == "atom") {
            list(params = list(search_query = q_val,
                               sortBy = "submittedDate", sortOrder = "descending"))
          } else if (row$type == "core_api") {
            list(query = q_val)
          } else if (row$type == "oai_pmh") {
            list(oai_from = q_val)
          }
        }
      }

      etl_log_text("")
      append_log <- function(msg) {
        etl_log_text(paste0(etl_log_text(),
                            format(Sys.time(), "[%H:%M:%S] "), msg, "\n"))
      }

      shiny::withProgress(message = "ETL работает...", value = 0, {
        append_log(paste0("Коллекторы: ",
                          if (is.null(sources)) "все enabled" else paste(sources, collapse = ", ")))
        append_log(paste0("max_results=", n_req, ", only_new=", only_new))
        shiny::incProgress(0.1)

        # Захватываем message() из etl()
        msgs <- character(0)
        withCallingHandlers(
          tryCatch(
            etl(max_results = n_req, only_new = only_new, sources = sources,
                param_overrides = param_overrides),
            error = function(e) append_log(paste("ERROR:", conditionMessage(e)))
          ),
          message = function(m) {
            append_log(trimws(conditionMessage(m)))
            invokeRestart("muffleMessage")
          }
        )
        shiny::incProgress(0.6)

        if (use_ml) {
          if (ml_service_is_healthy(ml_service_url)) {
            task_label <- ml_tasks_info[[task_id]]$label %||% task_id
            append_log(paste0("ML-классификация [задача: ", task_label, "]..."))
            raw <- tryCatch(load_publications(), error = function(e) NULL)
            if (!is.null(raw) && nrow(raw) > 0) {
              available <- tryCatch(
                names(list_ml_models(ml_service_url)$models),
                error = function(e) character(0)
              )
              ml_res <- tryCatch(
                .classify_by_language(raw, language_models, available, ml_service_url),
                error = function(e) { append_log(paste("ML ERROR:", conditionMessage(e))); NULL }
              )
              if (!is.null(ml_res) && nrow(ml_res) > 0) {
                upd <- update_ml_tags(ml_res, task_id = task_id)
                append_log(paste0("ML [", task_id, "]: обновлено ", upd$updated, " записей"))
              } else {
                append_log("ML: нет результатов (модели не загружены или пропущены).")
              }
            }
          } else {
            append_log(paste0("ML-сервис недоступен (", ml_service_url, "), пропущено."))
          }
        }
        shiny::incProgress(0.3)

        append_log("ETL завершён.")
        reload_publications()
        shiny::showNotification("ETL завершён", type = "message", duration = 4)
      })

      output$etl_status <- shiny::renderUI(
        shiny::span(class = "status-ok", "✓ Готово"))
    })

    output$etl_log <- shiny::renderText({ etl_log_text() })
    output$etl_result_table <- DT::renderDT({
      df <- publications()
      if (is.null(df) || nrow(df) == 0) return(NULL)
      df |>
        dplyr::arrange(dplyr::desc(ingested_at)) |>
        dplyr::select(dplyr::any_of(c("paper_id", "title", "source",
                                      "language", "tag", "published_date"))) |>
        head(20)
    }, options = list(pageLength = 10, scrollX = TRUE), rownames = FALSE)

    # ---- Таблица статей ----
    shiny::observe({
      df <- publications()
      if (is.null(df) || nrow(df) == 0) return()
      if ("published_date" %in% names(df)) {
        years <- sort(unique(format(as.POSIXct(df$published_date), "%Y")), decreasing = TRUE)
        years <- years[!is.na(years) & nzchar(years)]
        shiny::updateSelectInput(session, "tbl_year",
          choices = c("Все" = "", setNames(years, years)))
      }
      if ("source" %in% names(df)) {
        srcs <- sort(unique(df$source[!is.na(df$source) & nzchar(df$source)]))
        shiny::updateSelectInput(session, "tbl_source",
          choices = c("Все" = "", setNames(srcs, srcs)))
      }
      if ("language" %in% names(df)) {
        langs <- sort(unique(df$language[!is.na(df$language) & nzchar(df$language)]))
        shiny::updateSelectInput(session, "tbl_lang",
          choices = c("Все" = "", setNames(langs, langs)))
      }
      if ("tag" %in% names(df)) {
        tg <- sort(unique(df$tag[!is.na(df$tag)]))
        shiny::updateSelectInput(session, "tbl_tag",
          choices = c("Все" = "", setNames(tg, tg)))
      }
      # ML-задачи для таблицы
      task_ids <- get_ml_task_ids()
      tasks    <- tryCatch(load_ml_tasks(), error = function(e) list())
      if (length(task_ids) == 0) {
        shiny::updateSelectInput(session, "tbl_ml_task",
          choices = c("(нет ML-данных)" = ""), selected = "")
      } else {
        ch <- c("(не показывать)" = "",
                setNames(task_ids, vapply(task_ids, function(tid)
                  tasks[[tid]]$label %||% tid, character(1))))
        cur <- isolate(input$tbl_ml_task)
        # Сохранить выбор пользователя; если ещё не выбрано — взять первую задачу автоматически
        sel <- if (!is.null(cur) && nzchar(cur) && cur %in% task_ids) cur else task_ids[1]
        shiny::updateSelectInput(session, "tbl_ml_task", choices = ch, selected = sel)
      }
    })

    filtered <- shiny::reactive({
      df <- publications()
      if (is.null(df) || nrow(df) == 0) return(df)

      q <- trimws(input$tbl_search %||% "")
      if (nzchar(q)) {
        pat  <- tolower(q)
        keep <- grepl(pat, tolower(df$title    %||% ""), fixed = TRUE) |
                grepl(pat, tolower(df$abstract %||% ""), fixed = TRUE)
        df <- df[keep, , drop = FALSE]
      }
      y <- trimws(input$tbl_year %||% "")
      if (nzchar(y) && "published_date" %in% names(df)) {
        yrs <- format(as.POSIXct(df$published_date), "%Y")
        df  <- df[!is.na(yrs) & yrs == y, , drop = FALSE]
      }
      src <- trimws(input$tbl_source %||% "")
      if (nzchar(src) && "source" %in% names(df))
        df <- df[!is.na(df$source) & df$source == src, , drop = FALSE]

      lang <- trimws(input$tbl_lang %||% "")
      if (nzchar(lang) && "language" %in% names(df))
        df <- df[!is.na(df$language) & df$language == lang, , drop = FALSE]

      tg <- trimws(input$tbl_tag %||% "")
      if (nzchar(tg) && "tag" %in% names(df))
        df <- df[!is.na(df$tag) & df$tag == tg, , drop = FALSE]

      df
    })

    output$tbl_count <- shiny::renderText({
      df <- filtered(); if (is.null(df)) "—"
      else paste0("Показано: ", format(nrow(df), big.mark = " "), " статей")
    })
    output$tbl_main <- DT::renderDT({
      df      <- filtered()
      task_id <- trimws(input$tbl_ml_task %||% "")
      if (is.null(df) || nrow(df) == 0) return(NULL)

      base_cols <- c("paper_id", "title", "source", "language", "tag", "published_date", "link")
      show <- df[, intersect(base_cols, names(df)), drop = FALSE]

      # Добавить ML-результаты выбранной задачи с понятными именами колонок
      if (nzchar(task_id)) {
        df <- .extract_ml_task(df, task_id)
        show[[paste0("ML-тег (", task_id, ")")]]  <- df$ml_tag
        show[[paste0("ML-увер. (", task_id, ")")]] <- round(df$ml_confidence, 3)
      }

      title_idx <- which(names(show) == "title") - 1L
      DT::datatable(show, filter = "top", rownames = FALSE, escape = FALSE,
        options = list(pageLength = 15, scrollX = TRUE,
          columnDefs = if (length(title_idx) > 0) list(list(
            targets = title_idx,
            render  = DT::JS("function(d,t){",
              "if(t!='display')return d;",
              "if(!d)return '';",
              "return d.length>120?d.substr(0,120)+'…':d;","}")
          )) else list()
        )
      )
    })
    output$btn_tbl_export <- shiny::downloadHandler(
      filename = function() paste0("cyberarxiv_", Sys.Date(), ".csv"),
      content  = function(file) {
        df <- filtered()
        utils::write.csv(if (is.null(df)) data.frame() else df,
                         file, row.names = FALSE, fileEncoding = "UTF-8")
      }
    )
    shiny::observeEvent(input$btn_tbl_refresh, reload_publications())

    # ---- ML ----
    shiny::observeEvent(input$btn_ml_check, {
      ok <- tryCatch(ml_service_is_healthy(ml_service_url), error = function(e) FALSE)
      output$ml_info <- shiny::renderPrint({
        if (!isTRUE(ok)) {
          cat("STATUS: ✗ сервис недоступен\nURL:", ml_service_url, "\n")
          return()
        }
        cat("STATUS: ✓ OK\nURL:", ml_service_url, "\n\n")
        info <- tryCatch({
          resp <- httr2::request(ml_service_url) |>
            httr2::req_url_path("models") |>
            httr2::req_timeout(10) |>
            httr2::req_perform()
          httr2::resp_body_json(resp)
        }, error = function(e) list(error = conditionMessage(e)))

        if (!is.null(info$models) && length(info$models) > 0) {
          cat("Загружено моделей:", length(info$models), "\n")
          cat("По умолчанию:    ", info$default %||% "—", "\n\n")
          for (nm in names(info$models)) {
            m <- info$models[[nm]]
            cat(sprintf("  [%s]  %d классов  |  base: %s\n",
                        nm, m$num_classes %||% 0, m$base_model %||% "—"))
          }
        } else {
          cat("Нет загруженных моделей.\n")
          cat("Положи .pt файлы в MODELS_DIR.\n")
        }
      })

      # Обновить задачи с актуальными данными о загруженных моделях
      new_tasks   <- tryCatch(list_ml_tasks(ml_service_url), error = function(e) load_ml_tasks())
      new_choices <- setNames(names(new_tasks),
                              vapply(new_tasks, `[[`, character(1), "label"))
      ml_tasks_info   <<- new_tasks
      ml_task_choices <<- new_choices
      shiny::updateSelectInput(session, "ml_task_batch", choices = new_choices)
      shiny::updateSelectInput(session, "ml_task_adhoc", choices = new_choices)
      shiny::updateSelectInput(session, "etl_ml_task",   choices = new_choices)
    })

    output$ml_task_col_info <- shiny::renderUI({
      task_id <- trimws(input$ml_task_batch %||% names(ml_task_choices)[1])
      if (!nzchar(task_id)) return(NULL)
      shiny::div(
        style = "background:#f0f4f8; border-left:3px solid #00A896; padding:8px 12px; margin-bottom:10px; font-size:12px;",
        shiny::strong("Результат запишется в:"),
        shiny::br(),
        shiny::code(paste0("ml_results.", task_id))
      )
    })

    # ml_batch_progress — заглушка, реальный прогресс через shiny::withProgress
    output$ml_batch_progress <- shiny::renderUI(NULL)

    run_ml_batch <- function(only_new) {
      if (!ml_service_is_healthy(ml_service_url)) {
        ml_log_text(paste0("ML-сервис недоступен (", ml_service_url, ")."))
        return()
      }
      task_id   <- trimws(input$ml_task_batch %||% names(ml_task_choices)[1])
      lang_mdls <- (ml_tasks_info[[task_id]]$models) %||% list(en = "best_model")
      pubs <- publications()
      if (is.null(pubs) || nrow(pubs) == 0) {
        ml_log_text("База данных пустая. Сначала запусти ETL."); return()
      }

      df <- pubs
      df$id <- df$paper_id

      if (only_new) {
        df <- .extract_ml_task(df, task_id)
        df <- df[is.na(df$ml_tag), , drop = FALSE]
      }

      if (nrow(df) == 0) {
        ml_log_text(paste0("Все статьи уже классифицированы задачей «", task_id, "»."))
        return()
      }

      task_label <- ml_tasks_info[[task_id]]$label %||% task_id
      total      <- nrow(df)
      ml_log_text(paste0("Классификация ", total, " статей [задача: ", task_label, "]..."))

      available <- tryCatch(names(list_ml_models(ml_service_url)$models),
                            error = function(e) character(0))

      lang_col  <- if ("language" %in% names(df)) df$language else rep("en", nrow(df))
      lang_col[is.na(lang_col) | !nzchar(lang_col)] <- "en"
      all_results <- list()
      batch_size  <- 50L

      # withProgress обновляет прогресс-бар в браузере даже во время синхронного выполнения
      shiny::withProgress(message = paste0("Задача: ", task_label), value = 0, {
        processed <- 0L
        for (lang in unique(lang_col)) {
          group      <- df[lang_col == lang, , drop = FALSE]
          model_name <- lang_mdls[[lang]] %||% NULL
          if (is.null(model_name) || !nzchar(model_name)) {
            ml_log_text(paste0("  Язык '", lang, "': нет модели в задаче, пропущено."))
            next
          }
          if (length(available) > 0 && !model_name %in% available) {
            ml_log_text(paste0("  Язык '", lang, "': модель '", model_name, "' не загружена, пропущено."))
            next
          }

          n_batches <- ceiling(nrow(group) / batch_size)
          for (b in seq_len(n_batches)) {
            idx   <- seq((b - 1L) * batch_size + 1L, min(b * batch_size, nrow(group)))
            batch <- group[idx, , drop = FALSE]

            res <- tryCatch(
              classify_with_ml(batch, model = model_name, ml_service_url = ml_service_url),
              error = function(e) {
                ml_log_text(paste0("  ERROR [", lang, " батч ", b, "]: ", conditionMessage(e)))
                NULL
              }
            )
            if (!is.null(res)) all_results[[paste0(lang, "_", b)]] <- res

            processed <- processed + nrow(batch)
            shiny::setProgress(
              value   = processed / total,
              detail  = paste0(processed, " / ", total, " статей")
            )
          }
        }
      })

      if (length(all_results) == 0) {
        ml_log_text("Нет результатов — проверь что нужные модели загружены в ML-сервис.")
        return()
      }

      combined <- do.call(rbind, all_results)
      upd <- update_ml_tags(combined, task_id = task_id)
      ml_log_text(paste0("✓ Готово. Обновлено: ", upd$updated, " [", task_id, "]"))
      reload_publications()
    }

    shiny::observeEvent(input$btn_ml_run,     run_ml_batch(only_new = TRUE))
    shiny::observeEvent(input$btn_ml_run_all, run_ml_batch(only_new = FALSE))
    output$ml_batch_status <- shiny::renderText({ ml_log_text() })

    adhoc_result_data <- shiny::reactiveVal(NULL)

    shiny::observeEvent(input$btn_adhoc, {
      txt <- trimws(input$adhoc_text %||% "")
      if (!nzchar(txt)) {
        adhoc_result_data(list(error = "Пустой текст."))
        return()
      }

      if (!ml_service_is_healthy(ml_service_url)) {
        adhoc_result_data(list(error = paste0("ML-сервис недоступен: ", ml_service_url)))
        return()
      }

      task_id   <- trimws(input$ml_task_adhoc %||% names(ml_task_choices)[1])
      lang_sel  <- trimws(input$ml_adhoc_lang %||% "en")
      model_sel <- (ml_tasks_info[[task_id]]$models)[[lang_sel]] %||% ""

      if (!nzchar(model_sel)) {
        adhoc_result_data(list(error = paste0(
          "У задачи «", task_id, "» нет модели для языка «", lang_sel, "».",
          " Проверь ml_tasks.yml и загруженные модели."
        )))
        return()
      }

      adhoc_result_data(list(loading = TRUE, model = model_sel))

      res <- tryCatch({
        req <- httr2::request(ml_service_url) |>
          httr2::req_url_path("classify_single") |>
          httr2::req_body_json(list(id = "adhoc", abstract = txt)) |>
          httr2::req_url_query(model = model_sel) |>
          httr2::req_timeout(30)
        httr2::resp_body_json(httr2::req_perform(req))
      }, error = function(e) list(error = conditionMessage(e)))

      adhoc_result_data(res)
    })

    output$adhoc_result <- shiny::renderUI({
      res <- adhoc_result_data()
      if (is.null(res)) return(NULL)

      if (isTRUE(res$loading))
        return(shiny::div(class = "status-idle", paste0("Классификация моделью «", res$model, "»…")))

      if (!is.null(res$error))
        return(shiny::div(class = "status-fail",
          shiny::strong("Ошибка: "), res$error))

      conf_pct <- sprintf("%.1f%%", (res$confidence %||% 0) * 100)
      shiny::div(
        shiny::h5(paste0("Предсказание (модель: ", res$model_used %||% "default", "):")),
        shiny::div(style = "font-size:22px;font-weight:700;color:#1e3a5f;",
                   res$tag %||% "—"),
        shiny::div(class = "status-idle", "Уверенность: ", conf_pct),
        if (!is.null(res$all_scores)) {
          top <- utils::head(sort(unlist(res$all_scores), decreasing = TRUE), 5)
          shiny::tagList(
            shiny::h6("Топ-5 классов:"),
            shiny::tags$ul(lapply(names(top), function(k)
              shiny::tags$li(k, ": ", sprintf("%.3f", top[[k]]))))
          )
        }
      )
    })

    # ---- Аналитика ----
    output$plot_authors <- plotly::renderPlotly({
      df <- publications()
      if (is.null(df) || nrow(df) == 0 || !"authors" %in% names(df))
        return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      auth <- df |>
        dplyr::filter(!is.na(authors)) |>
        dplyr::mutate(authors = stringr::str_split(authors, ",\\s*")) |>
        tidyr::unnest(authors) |>
        dplyr::mutate(authors = stringr::str_trim(authors)) |>
        dplyr::filter(nzchar(authors)) |>
        dplyr::count(authors, sort = TRUE) |>
        utils::head(15)
      plotly::plot_ly(auth, x = ~reorder(authors, n), y = ~n, type = "bar",
                      marker = list(color = "#2ca02c")) |>
        plotly::layout(xaxis = list(tickangle = -45, title = ""),
                       yaxis = list(title = "Публикаций"))
    })
    output$plot_words <- plotly::renderPlotly({
      df <- publications()
      if (is.null(df) || nrow(df) == 0)
        return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      words <- tryCatch(get_top_words(df, n = 25), error = function(e) NULL)
      if (is.null(words) || nrow(words) == 0)
        return(plotly::plot_ly() |> plotly::layout(title = "Недостаточно данных"))
      plotly::plot_ly(words, x = ~reorder(word, n), y = ~n, type = "bar",
                      marker = list(color = "#9467bd")) |>
        plotly::layout(xaxis = list(tickangle = -45, title = ""),
                       yaxis = list(title = "Частота"))
    })
    output$cross_tab <- DT::renderDT({
      df      <- publications()
      task_id <- trimws(input$analytics_ml_task %||% "")
      if (is.null(df) || nrow(df) == 0 || !"tag" %in% names(df)) return(NULL)
      if (!nzchar(task_id)) return(NULL)
      df <- .extract_ml_task(df, task_id)
      sub <- df[!is.na(df$tag) & !is.na(df$ml_tag) & nzchar(df$ml_tag), , drop = FALSE]
      if (nrow(sub) == 0) return(NULL)
      tab <- as.data.frame.matrix(table(sub$tag, sub$ml_tag))
      tab$keyword_tag <- rownames(tab)
      tab <- tab[, c("keyword_tag", setdiff(names(tab), "keyword_tag"))]
      DT::datatable(tab, rownames = FALSE,
                    options = list(pageLength = 20, scrollX = TRUE))
    })

    output$plot_sources_analytics <- plotly::renderPlotly({
      df <- publications()
      if (is.null(df) || nrow(df) == 0 || !"source" %in% names(df))
        return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      cnts <- dplyr::count(df, source, sort = TRUE)
      plotly::plot_ly(cnts, x = ~reorder(source, n), y = ~n, type = "bar",
                      marker = list(color = "#2c5282")) |>
        plotly::layout(xaxis = list(title = ""),
                       yaxis = list(title = "Статей"),
                       margin = list(b = 70))
    })

    output$plot_by_year <- plotly::renderPlotly({
      df <- publications()
      if (is.null(df) || nrow(df) == 0 || !"published_date" %in% names(df))
        return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      df2 <- df |>
        dplyr::mutate(year = format(as.POSIXct(published_date), "%Y")) |>
        dplyr::filter(!is.na(year), nzchar(year)) |>
        dplyr::count(year) |>
        dplyr::arrange(year)
      if (nrow(df2) == 0) return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      plotly::plot_ly(df2, x = ~year, y = ~n, type = "bar",
                      marker = list(color = "#1d4ed8")) |>
        plotly::layout(xaxis = list(title = "Год"),
                       yaxis = list(title = "Статей"))
    })

    output$plot_conf_by_tag <- plotly::renderPlotly({
      df       <- publications()
      task_id  <- trimws(input$analytics_ml_task %||% "")
      if (is.null(df) || nrow(df) == 0 || !nzchar(task_id) || !"tag" %in% names(df))
        return(plotly::plot_ly() |> plotly::layout(title = "Нет ML-данных"))
      df <- .extract_ml_task(df, task_id)
      avg <- df |>
        dplyr::filter(!is.na(tag), !is.na(ml_confidence)) |>
        dplyr::group_by(tag) |>
        dplyr::summarise(avg_conf = mean(ml_confidence, na.rm = TRUE),
                         n = dplyr::n(), .groups = "drop") |>
        dplyr::arrange(dplyr::desc(avg_conf)) |>
        head(15)
      if (nrow(avg) == 0) return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      plotly::plot_ly(avg, x = ~reorder(tag, avg_conf), y = ~avg_conf, type = "bar",
                      marker = list(
                        color = ~avg_conf,
                        colorscale = list(c(0, "#fca5a5"), c(0.5, "#fbbf24"), c(1, "#15803d")),
                        showscale = FALSE
                      )) |>
        plotly::layout(xaxis = list(tickangle = -45, title = ""),
                       yaxis = list(title = "Ср. confidence", range = c(0, 1)))
    })

    output$plot_ml_coverage <- plotly::renderPlotly({
      df      <- publications()
      task_id <- trimws(input$analytics_ml_task %||% "")
      if (is.null(df) || nrow(df) == 0)
        return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      has_kw <- !is.na(df$tag) & nzchar(df$tag)
      if (nzchar(task_id)) {
        df <- .extract_ml_task(df, task_id)
        has_ml <- !is.na(df$ml_tag) & nzchar(df$ml_tag)
      } else {
        has_ml <- rep(FALSE, nrow(df))
      }
      cov <- data.frame(
        group = c("Keyword + ML", "Только keyword", "Без тегов"),
        n     = c(sum(has_kw & has_ml), sum(has_kw & !has_ml), sum(!has_kw)),
        color = c("#15803d", "#2c5282", "#9ca3af"),
        stringsAsFactors = FALSE
      )
      cov <- cov[cov$n > 0, ]
      plotly::plot_ly(cov, x = ~group, y = ~n, type = "bar",
                      marker = list(color = ~color)) |>
        plotly::layout(xaxis = list(title = ""),
                       yaxis = list(title = "Статей"),
                       showlegend = FALSE)
    })

    # Обновить список доступных задач в аналитике при перезагрузке данных
    shiny::observe({
      df <- publications()
      if (is.null(df) || nrow(df) == 0) return()
      task_ids <- get_ml_task_ids()
      if (length(task_ids) == 0) {
        shiny::updateSelectInput(session, "analytics_ml_task",
                                 choices = c("(нет ML-данных)" = ""), selected = "")
      } else {
        tasks   <- tryCatch(load_ml_tasks(), error = function(e) list())
        choices <- setNames(task_ids, vapply(task_ids, function(tid) {
          tasks[[tid]]$label %||% tid
        }, character(1)))
        cur <- isolate(input$analytics_ml_task)
        sel <- if (!is.null(cur) && nzchar(cur) && cur %in% task_ids) cur else task_ids[1]
        shiny::updateSelectInput(session, "analytics_ml_task",
                                 choices = choices, selected = sel)
      }
    })

    output$plot_ml_conf <- plotly::renderPlotly({
      df      <- publications()
      task_id <- trimws(input$analytics_ml_task %||% "")
      if (is.null(df) || nrow(df) == 0 || !nzchar(task_id))
        return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      df <- .extract_ml_task(df, task_id)
      conf <- as.numeric(df$ml_confidence)
      conf <- conf[!is.na(conf)]
      if (length(conf) == 0)
        return(plotly::plot_ly() |> plotly::layout(title = "Нет ML-данных для этой задачи"))
      plotly::plot_ly(x = conf, type = "histogram", nbinsx = 20,
                      marker = list(color = "#ff7f0e",
                                    line = list(color = "white", width = 0.5))) |>
        plotly::layout(xaxis = list(title = "Уверенность"),
                       yaxis = list(title = "Кол-во статей"))
    })

    output$plot_tag_comparison <- plotly::renderPlotly({
      df      <- publications()
      task_id <- trimws(input$analytics_ml_task %||% "")
      if (is.null(df) || nrow(df) == 0 || !"tag" %in% names(df))
        return(plotly::plot_ly() |> plotly::layout(title = "Нет данных"))
      kw <- df |>
        dplyr::filter(!is.na(tag)) |>
        dplyr::count(tag, sort = TRUE) |>
        head(15) |>
        dplyr::rename(category = tag) |>
        dplyr::mutate(type = "Keyword")
      df <- .extract_ml_task(df, task_id)
      has_ml <- nzchar(task_id) &&
                any(!is.na(df$ml_tag) & nzchar(df$ml_tag))
      if (has_ml) {
        ml <- df[!is.na(df$ml_tag) & nzchar(df$ml_tag), ] |>
          dplyr::count(ml_tag, sort = TRUE) |>
          head(15) |>
          dplyr::rename(category = ml_tag) |>
          dplyr::mutate(type = paste0("ML (", task_id, ")"))
        combined <- rbind(kw, ml)
      } else {
        combined <- kw
      }
      plotly::plot_ly(combined, x = ~category, y = ~n, color = ~type, type = "bar") |>
        plotly::layout(barmode = "group",
                       xaxis = list(tickangle = -40, title = ""),
                       yaxis = list(title = "Статей"),
                       margin = list(b = 110),
                       legend = list(orientation = "h", x = 0, y = -0.4))
    })

    # ============================================================
    # ---- Обучение модели (training pipeline) ----
    # ============================================================
    #
    # State for the Training tab. We poll active jobs every 2 seconds via
    # invalidateLater so progress/log update without manual refresh. Only
    # one job per type can be tracked at a time (collect/label/train) —
    # the user can still spawn extras through R but the UI surfaces the
    # most recent.

    tr_active_collect <- shiny::reactiveVal(NULL)
    tr_active_label   <- shiny::reactiveVal(NULL)
    tr_active_train   <- shiny::reactiveVal(NULL)
    tr_active_excel   <- shiny::reactiveVal(NULL)
    tr_classes_state  <- shiny::reactiveVal(NULL)

    .tr_safe <- function(expr, fail = NULL) tryCatch(expr, error = function(e) fail)

    .tr_format_bytes <- function(b) {
      if (is.null(b) || is.na(b)) return("—")
      units <- c("B","KB","MB","GB","TB")
      i <- 1
      while (b >= 1024 && i < length(units)) { b <- b / 1024; i <- i + 1 }
      sprintf("%.1f %s", b, units[i])
    }

    .tr_render_progress <- function(job) {
      if (is.null(job)) return(NULL)
      pct  <- as.integer(round((job$progress %||% 0) * 100))
      stat <- job$status %||% "—"
      bar_color <- switch(stat,
        completed = "#2e7d32", failed = "#c62828",
        cancelled = "#757575", running = "#1565c0", "#888"
      )
      shiny::div(
        style = "background:#eee; border-radius:4px; overflow:hidden; height:18px; margin-top:6px;",
        shiny::div(style = paste0(
          "width:", pct, "%; height:100%; background:", bar_color, "; ",
          "transition:width .3s; color:white; font-size:11px; ",
          "text-align:center; line-height:18px;"),
          paste0(stat, " · ", pct, "%"))
      )
    }

    # Initial config load (defer to first time user opens the tab — it
    # touches the network)
    tr_load_config <- function() {
      res <- .tr_safe(training_get_config_safe(ml_service_url),
                      list(ok = FALSE, error = "internal R error", data = NULL))
      if (!isTRUE(res$ok)) {
        msg <- paste0("Не удалось загрузить training-конфиг: ", res$error %||% "unknown")
        output$tr_classes_status <- shiny::renderText(msg)
        output$tr_prompts_status <- shiny::renderText(msg)
        output$tr_llm_status     <- shiny::renderText(msg)
        return()
      }
      cfg <- res$data
      tr_classes_state(cfg$classes)

      shiny::updateTextAreaInput(session, "tr_system_prompt",
                                 value = cfg$system_prompt %||% "")
      shiny::updateTextAreaInput(session, "tr_user_template",
                                 value = cfg$user_prompt_template %||% "")
      llm <- cfg$llm %||% list()
      shiny::updateSelectInput(session, "tr_llm_provider",
                               selected = llm$provider %||% "openai")
      shiny::updateTextInput(session, "tr_llm_model",
                             value = llm$model %||% "gpt-4o-mini")
      shiny::updateTextInput(session, "tr_llm_base_url",
                             value = llm$base_url %||% "")
      shiny::updateNumericInput(session, "tr_llm_temp",
                                value = llm$temperature %||% 0)
      shiny::updateNumericInput(session, "tr_llm_max_tokens",
                                value = llm$max_tokens %||% 32)
      shiny::updateNumericInput(session, "tr_llm_concurrency",
                                value = llm$concurrency %||% 4)
      shiny::updateNumericInput(session, "tr_llm_timeout",
                                value = llm$request_timeout_secs %||% 60)
      key_set <- isTRUE(llm$api_key_set)
      stat <- if (key_set) paste0("✓ key stored (", llm$api_key %||% "***", ")")
              else "ключ не задан"
      output$tr_llm_status <- shiny::renderText(stat)
    }
    shiny::isolate(tr_load_config())

    # ---------- Конфигурация: классы (rhandsontable) ----------
    output$tr_classes_table <- rhandsontable::renderRHandsontable({
      classes <- tr_classes_state()
      if (is.null(classes) || length(classes) == 0) {
        df <- data.frame(name = character(), description = character(),
                         stringsAsFactors = FALSE)
      } else {
        df <- do.call(rbind, lapply(classes, function(c) {
          data.frame(name = c$name %||% "",
                     description = c$description %||% "",
                     stringsAsFactors = FALSE)
        }))
      }
      rhandsontable::rhandsontable(df, rowHeaders = NULL, height = 320, useTypes = TRUE) |>
        rhandsontable::hot_col("name", width = 180) |>
        rhandsontable::hot_col("description", width = 380)
    })

    shiny::observeEvent(input$btn_tr_class_add, {
      classes <- tr_classes_state() %||% list()
      tbl <- .tr_safe(rhandsontable::hot_to_r(input$tr_classes_table), NULL)
      if (!is.null(tbl) && nrow(tbl) > 0) {
        classes <- lapply(seq_len(nrow(tbl)), function(i)
          list(name = tbl$name[i] %||% "", description = tbl$description[i] %||% ""))
      }
      classes[[length(classes) + 1]] <- list(name = "new_class", description = "")
      tr_classes_state(classes)
    })

    shiny::observeEvent(input$btn_tr_class_save, {
      tbl <- .tr_safe(rhandsontable::hot_to_r(input$tr_classes_table), NULL)
      if (is.null(tbl) || nrow(tbl) == 0) {
        output$tr_classes_status <- shiny::renderText("Таблица пуста.")
        return()
      }
      classes <- lapply(seq_len(nrow(tbl)), function(i) {
        list(name = trimws(tbl$name[i]),
             description = trimws(tbl$description[i] %||% ""))
      })
      classes <- Filter(function(c) nzchar(c$name), classes)
      res <- .tr_safe(training_set_config_safe(classes = classes,
                                               ml_service_url = ml_service_url),
                      list(ok = FALSE, error = "internal R error"))
      if (isTRUE(res$ok) && !is.null(res$data$classes)) {
        tr_classes_state(res$data$classes)
        output$tr_classes_status <- shiny::renderText(
          paste0("✓ Сохранено: ", length(res$data$classes), " классов."))
      } else {
        output$tr_classes_status <- shiny::renderText(
          paste0("Ошибка: ", res$error %||% "unknown"))
      }
    })

    shiny::observeEvent(input$btn_tr_prompts_save, {
      res <- .tr_safe(training_set_config_safe(
        system_prompt = input$tr_system_prompt,
        user_prompt_template = input$tr_user_template,
        ml_service_url = ml_service_url
      ), list(ok = FALSE, error = "internal R error"))
      if (isTRUE(res$ok)) {
        output$tr_prompts_status <- shiny::renderText("✓ Промпты сохранены.")
      } else {
        output$tr_prompts_status <- shiny::renderText(
          paste0("Ошибка: ", res$error %||% "unknown"))
      }
    })

    shiny::observeEvent(input$btn_tr_health, {
      url <- ml_service_url
      txt <- tryCatch({
        req <- httr2::request(url) |>
          httr2::req_url_path("training/health") |>
          httr2::req_timeout(15) |>
          httr2::req_error(is_error = function(r) FALSE)
        resp <- httr2::req_perform(req)
        status <- httr2::resp_status(resp)
        body <- httr2::resp_body_string(resp)
        if (status >= 400) {
          paste0("HTTP ", status, ":\n", substr(body, 1, 1000))
        } else {
          j <- jsonlite::fromJSON(body, simplifyVector = TRUE)
          err_text <- if (length(j$errors %||% list()) > 0)
            paste("\nERRORS:", paste(unlist(j$errors), collapse = "; "))
          else ""
          sdks <- j$sdks %||% list()
          paste0("status: ", if (isTRUE(j$ok)) "✓ OK" else "✗ FAIL", "\n",
                 "training_data_dir: ", j$training_data_dir %||% "—", "\n",
                 "config_path: ", j$config_path %||% "—", "\n",
                 "config_writable: ", isTRUE(j$config_writable), "\n",
                 "sdks: openai=", isTRUE(sdks$openai),
                 ", anthropic=", isTRUE(sdks$anthropic),
                 err_text)
        }
      }, error = function(e) paste("transport error:", conditionMessage(e)))
      output$tr_health_info <- shiny::renderText(txt)
    })

    shiny::observeEvent(input$btn_tr_llm_save, {
      llm <- list(
        provider = input$tr_llm_provider,
        model = input$tr_llm_model,
        base_url = input$tr_llm_base_url,
        temperature = input$tr_llm_temp,
        max_tokens = as.integer(input$tr_llm_max_tokens),
        concurrency = as.integer(input$tr_llm_concurrency),
        request_timeout_secs = as.integer(input$tr_llm_timeout)
      )
      key <- trimws(input$tr_llm_api_key %||% "")
      if (nzchar(key)) llm$api_key <- key
      res <- .tr_safe(training_set_config_safe(llm = llm,
                                               ml_service_url = ml_service_url),
                      list(ok = FALSE, error = "internal R error"))
      if (isTRUE(res$ok)) {
        shiny::updateTextInput(session, "tr_llm_api_key", value = "")
        tr_load_config()
        output$tr_llm_status <- shiny::renderText("✓ LLM-настройки сохранены.")
      } else {
        output$tr_llm_status <- shiny::renderText(
          paste0("Ошибка: ", res$error %||% "unknown"))
      }
    })

    # ---------- Сбор данных ----------
    .tr_render_files <- function(category, output_id) {
      output[[output_id]] <- DT::renderDT({
        files <- .tr_safe(training_list_files(category, ml_service_url), list())
        if (length(files) == 0)
          return(DT::datatable(data.frame(name = character(), size = character(),
                                          modified = character()),
                                rownames = FALSE))
        df <- do.call(rbind, lapply(files, function(f) {
          data.frame(
            name = f$name %||% "",
            size = .tr_format_bytes(f$size %||% 0),
            modified = format(as.POSIXct(f$mtime %||% 0, origin = "1970-01-01"),
                              "%Y-%m-%d %H:%M:%S"),
            stringsAsFactors = FALSE
          )
        }))
        DT::datatable(df, rownames = FALSE, selection = "single",
                      options = list(pageLength = 10, scrollX = TRUE))
      })
    }
    .tr_render_files("raw", "tr_files_raw")
    .tr_render_files("labeled", "tr_files_labeled")
    .tr_render_files("excel", "tr_files_excel")

    shiny::observeEvent(input$btn_tr_files_raw_refresh, .tr_render_files("raw", "tr_files_raw"))
    shiny::observeEvent(input$btn_tr_files_labeled_refresh,
                        .tr_render_files("labeled", "tr_files_labeled"))
    shiny::observeEvent(input$btn_tr_files_excel_refresh,
                        .tr_render_files("excel", "tr_files_excel"))

    shiny::observeEvent(input$btn_tr_collect, {
      target <- as.integer(input$tr_collect_target)
      query <- trimws(input$tr_collect_query %||% "")
      job_id <- .tr_safe(training_start_collect(
        target = target,
        query = if (nzchar(query)) query else NULL,
        page_size = as.integer(input$tr_collect_page_size),
        ml_service_url = ml_service_url
      ), NULL)
      if (is.null(job_id)) {
        output$tr_collect_status <- shiny::renderText(
          "Ошибка: не удалось запустить сбор.")
        return()
      }
      tr_active_collect(job_id)
      shiny::showNotification(paste0("Запущен сбор, job_id=", substr(job_id, 1, 8), "…"),
                              type = "message", duration = 4)
    })

    # Polled state for collect job
    tr_collect_job <- shiny::reactivePoll(
      intervalMillis = 2500, session = session,
      checkFunc = function() {
        list(jid = tr_active_collect(), t = Sys.time())
      },
      valueFunc = function() {
        jid <- tr_active_collect()
        if (is.null(jid)) return(NULL)
        training_get_job(jid, ml_service_url)
      }
    )

    output$tr_collect_status <- shiny::renderText({
      job <- tr_collect_job()
      if (is.null(job)) return("idle")
      paste0("status=", job$status %||% "—",
             "  progress=", sprintf("%.0f%%", (job$progress %||% 0) * 100),
             if (!is.null(job$error)) paste0("\nerror: ", job$error) else "")
    })
    output$tr_collect_progress <- shiny::renderUI(.tr_render_progress(tr_collect_job()))
    output$tr_collect_log <- shiny::renderText({
      job <- tr_collect_job()
      if (is.null(job) || length(job$log) == 0) return("")
      paste(utils::tail(unlist(job$log), 200), collapse = "\n")
    })

    # ---------- Разметка LLM ----------
    tr_raw_files <- shiny::reactivePoll(
      intervalMillis = 5000, session = session,
      checkFunc = function() {
        list(refresh = input$btn_tr_files_raw_refresh,
             job_tick = tr_collect_job(),
             subtab = input$tr_subtabs, ts = Sys.time())
      },
      valueFunc = function() {
        .tr_safe(training_list_files("raw", ml_service_url), list())
      }
    )
    output$ui_tr_label_raw_pick <- shiny::renderUI({
      files <- tr_raw_files()
      names_v <- vapply(files, function(f) f$name %||% "", character(1))
      current <- shiny::isolate(input$tr_label_raw_path)
      sel <- if (!is.null(current) && current %in% names_v) current
             else (if (length(names_v) > 0) names_v[1] else "—")
      shiny::selectInput("tr_label_raw_path", "Файл сырых данных:",
                         choices = if (length(names_v) > 0) names_v else "—",
                         selected = sel)
    })

    shiny::observeEvent(input$btn_tr_label, {
      raw_path <- input$tr_label_raw_path
      if (is.null(raw_path) || raw_path == "" || raw_path == "—") {
        output$tr_label_status <- shiny::renderText("Сначала выбери файл.")
        return()
      }
      job_id <- .tr_safe(training_start_label(
        raw_path = raw_path,
        max_rows = as.integer(input$tr_label_max_rows),
        ml_service_url = ml_service_url
      ), NULL)
      if (is.null(job_id)) {
        output$tr_label_status <- shiny::renderText(
          "Ошибка: разметка не запущена (проверь api_key).")
        return()
      }
      tr_active_label(job_id)
    })
    shiny::observeEvent(input$btn_tr_label_cancel, {
      jid <- tr_active_label()
      if (!is.null(jid)) .tr_safe(training_cancel_job(jid, ml_service_url), NULL)
    })

    tr_label_job <- shiny::reactivePoll(
      intervalMillis = 2500, session = session,
      checkFunc = function() list(jid = tr_active_label(), t = Sys.time()),
      valueFunc = function() {
        jid <- tr_active_label(); if (is.null(jid)) return(NULL)
        training_get_job(jid, ml_service_url)
      }
    )
    output$tr_label_status <- shiny::renderText({
      job <- tr_label_job()
      if (is.null(job)) return("idle")
      paste0("status=", job$status %||% "—",
             "  progress=", sprintf("%.0f%%", (job$progress %||% 0) * 100))
    })
    output$tr_label_progress <- shiny::renderUI(.tr_render_progress(tr_label_job()))
    output$tr_label_log <- shiny::renderText({
      job <- tr_label_job()
      if (is.null(job) || length(job$log) == 0) return("")
      paste(utils::tail(unlist(job$log), 200), collapse = "\n")
    })

    # ---------- Excel ----------
    tr_labeled_files <- shiny::reactivePoll(
      intervalMillis = 5000, session = session,
      checkFunc = function() {
        list(refresh = input$btn_tr_files_labeled_refresh,
             job_tick = tr_label_job(),
             subtab = input$tr_subtabs, ts = Sys.time())
      },
      valueFunc = function() {
        .tr_safe(training_list_files("labeled", ml_service_url), list())
      }
    )
    output$ui_tr_excel_labeled_pick <- shiny::renderUI({
      files <- tr_labeled_files()
      names_v <- vapply(files, function(f) f$name %||% "", character(1))
      current <- shiny::isolate(input$tr_excel_labeled_path)
      sel <- if (!is.null(current) && current %in% names_v) current
             else (if (length(names_v) > 0) names_v[1] else "—")
      shiny::selectInput("tr_excel_labeled_path", "Файл размеченных данных:",
                         choices = if (length(names_v) > 0) names_v else "—",
                         selected = sel)
    })

    shiny::observeEvent(input$btn_tr_export_excel, {
      lp <- input$tr_excel_labeled_path
      if (is.null(lp) || lp == "" || lp == "—") {
        output$tr_excel_status <- shiny::renderText("Сначала выбери файл.")
        return()
      }
      job_id <- .tr_safe(training_start_export_excel(
        labeled_path = lp,
        max_rows = as.integer(input$tr_excel_max_rows),
        ml_service_url = ml_service_url
      ), NULL)
      tr_active_excel(job_id)
    })

    tr_excel_job <- shiny::reactivePoll(
      intervalMillis = 2000, session = session,
      checkFunc = function() list(jid = tr_active_excel(), t = Sys.time()),
      valueFunc = function() {
        jid <- tr_active_excel(); if (is.null(jid)) return(NULL)
        training_get_job(jid, ml_service_url)
      }
    )
    output$tr_excel_status <- shiny::renderText({
      job <- tr_excel_job()
      if (is.null(job)) return("idle")
      lines <- c(paste0("status=", job$status %||% "—"))
      if (!is.null(job$result$filename))
        lines <- c(lines, paste0("file: ", job$result$filename))
      if (!is.null(job$error) && nzchar(job$error %||% ""))
        lines <- c(lines, paste0("error: ", job$error))
      if (length(job$log %||% list()) > 0) {
        last <- utils::tail(unlist(job$log), 30)
        lines <- c(lines, "--- log (last 30) ---", last)
      }
      paste(lines, collapse = "\n")
    })

    # ---------- Обучение ----------
    # Reactive list of available .xlsx — refreshes on the polled excel-job
    # tick, on every visit to the Training subtab, and on the manual Refresh
    # button. Without this, when a user clicks through tabs the dropdown
    # would only reflect the snapshot taken on first render.
    tr_excel_files <- shiny::reactivePoll(
      intervalMillis = 5000, session = session,
      checkFunc = function() {
        list(
          refresh = input$btn_tr_files_excel_refresh,
          job_tick = tr_excel_job(),
          subtab = input$tr_subtabs,
          ts = Sys.time()
        )
      },
      valueFunc = function() {
        .tr_safe(training_list_files("excel", ml_service_url), list())
      }
    )

    output$ui_tr_train_excel_pick <- shiny::renderUI({
      files <- tr_excel_files()
      names_v <- vapply(files, function(f) f$name %||% "", character(1))
      # Preserve the user's current selection across re-renders so the
      # dropdown does not silently snap back to the first item every time
      # the file list refreshes.
      current <- shiny::isolate(input$tr_train_excel_path)
      sel <- if (!is.null(current) && current %in% names_v) current
             else (if (length(names_v) > 0) names_v[1] else "—")
      shiny::selectInput("tr_train_excel_path", "Файл .xlsx с разметкой:",
                         choices = if (length(names_v) > 0) names_v else "—",
                         selected = sel)
    })

    shiny::observeEvent(input$btn_tr_train, {
      ep <- input$tr_train_excel_path
      if (is.null(ep) || ep == "" || ep == "—") {
        output$tr_train_status <- shiny::renderText("Сначала выбери .xlsx.")
        return()
      }
      mlflow_uri <- trimws(input$tr_train_mlflow_uri %||% "")
      if (!nzchar(mlflow_uri))
        mlflow_uri <- Sys.getenv("MLFLOW_TRACKING_URI", "http://localhost:5000")
      job_id <- .tr_safe(training_start_train(
        excel_path = ep,
        model_name_out = input$tr_train_model_name,
        base_model = input$tr_train_base_model,
        epochs = as.integer(input$tr_train_epochs),
        batch_size = as.integer(input$tr_train_batch_size),
        lr = as.numeric(input$tr_train_lr),
        max_length = as.integer(input$tr_train_max_length),
        test_size = as.numeric(input$tr_train_test_size),
        val_size = as.numeric(input$tr_train_val_size),
        mlflow_tracking_uri = mlflow_uri,
        ml_service_url = ml_service_url
      ), NULL)
      tr_active_train(job_id)
    })
    shiny::observeEvent(input$btn_tr_train_cancel, {
      jid <- tr_active_train()
      if (!is.null(jid)) .tr_safe(training_cancel_job(jid, ml_service_url), NULL)
    })

    tr_train_job <- shiny::reactivePoll(
      intervalMillis = 2000, session = session,
      checkFunc = function() list(jid = tr_active_train(), t = Sys.time()),
      valueFunc = function() {
        jid <- tr_active_train(); if (is.null(jid)) return(NULL)
        training_get_job(jid, ml_service_url)
      }
    )
    output$tr_train_status <- shiny::renderText({
      job <- tr_train_job()
      if (is.null(job)) return("idle")
      paste0("status=", job$status %||% "—",
             "  progress=", sprintf("%.0f%%", (job$progress %||% 0) * 100),
             if (!is.null(job$result$checkpoint))
               paste0("\nfile: ", basename(job$result$checkpoint)) else "")
    })
    output$tr_train_progress <- shiny::renderUI(.tr_render_progress(tr_train_job()))
    output$tr_train_log <- shiny::renderText({
      job <- tr_train_job()
      if (is.null(job) || length(job$log) == 0) return("")
      paste(utils::tail(unlist(job$log), 400), collapse = "\n")
    })
    output$tr_mlflow_link <- shiny::renderUI({
      uri <- Sys.getenv("MLFLOW_UI_URL", "http://localhost:5000")
      shiny::tags$a(href = uri, target = "_blank",
                    paste0("Открыть MLflow UI (", uri, ")"))
    })

    shiny::observeEvent(input$btn_tr_reload_models, {
      res <- .tr_safe(training_reload_models(ml_service_url), NULL)
      if (is.null(res)) {
        output$tr_reload_status <- shiny::renderText("Ошибка перезагрузки.")
      } else {
        output$tr_reload_status <- shiny::renderText(
          paste0("✓ Загружено: ",
                 paste(unlist(res$models %||% list()), collapse = ", ")))
      }
    })

    # Register a freshly-trained model as an ML task entry that the dropdowns
    # on the ML and ETL tabs can pick up. Writes to a user override yaml so
    # we never touch the package-bundled inst/ml_tasks.yml.
    shiny::observeEvent(input$btn_tr_register_task, {
      task_name <- trimws(input$tr_register_task_name %||% "")
      label     <- trimws(input$tr_register_task_label %||% "")
      lang      <- trimws(input$tr_register_task_lang %||% "en")
      model_nm  <- trimws(input$tr_train_model_name %||% "")

      if (!nzchar(task_name) || !nzchar(label) || !nzchar(model_nm)) {
        output$tr_register_status <- shiny::renderText(
          "Заполни идентификатор задачи, label и убедись, что Имя выходной модели задано выше.")
        return()
      }
      res <- tryCatch(
        register_ml_task(task_name = task_name, label = label,
                          model_name = model_nm, language = lang),
        error = function(e) list(error = conditionMessage(e))
      )
      if (!is.null(res$error)) {
        output$tr_register_status <- shiny::renderText(
          paste0("Ошибка: ", res$error))
        return()
      }

      # Refresh the in-memory task tables so subsequent UI re-renders pick
      # up the new entry without a Shiny restart.
      new_tasks   <- tryCatch(load_ml_tasks(), error = function(e) ml_tasks_info)
      new_choices <- setNames(names(new_tasks),
                              vapply(new_tasks, `[[`, character(1), "label"))
      ml_tasks_info   <<- new_tasks
      ml_task_choices <<- new_choices
      shiny::updateSelectInput(session, "ml_task_batch", choices = new_choices)
      shiny::updateSelectInput(session, "ml_task_adhoc", choices = new_choices)
      shiny::updateSelectInput(session, "etl_ml_task",   choices = new_choices)

      output$tr_register_status <- shiny::renderText(
        paste0("✓ Задача '", task_name, "' зарегистрирована (",
               lang, " → ", model_nm, "). ",
               "Зайди на вкладку ML-классификатор — она уже в дропдауне."))
    })

    # ---------- Все джобы ----------
    # Reactive list of jobs, refreshing every 4 seconds while the Джобы
    # subtab is visible. Without polling the table only updated on
    # button-click, which was confusing during long training runs.
    tr_jobs_data <- shiny::reactivePoll(
      intervalMillis = 4000, session = session,
      checkFunc = function() list(
        refresh = input$btn_tr_jobs_refresh,
        subtab = input$tr_subtabs,
        ts = Sys.time()
      ),
      valueFunc = function() {
        .tr_safe(training_list_jobs(limit = 100,
                                    ml_service_url = ml_service_url), list())
      }
    )

    output$tr_jobs_table <- DT::renderDT({
      jobs <- tr_jobs_data()
      if (length(jobs) == 0)
        return(DT::datatable(data.frame(), rownames = FALSE))
      df <- do.call(rbind, lapply(jobs, function(j) {
        log_lines <- j$log %||% list()
        last_log  <- if (length(log_lines) > 0) tail(unlist(log_lines), 1) else ""
        data.frame(
          id       = substr(j$id %||% "", 1, 8),
          type     = j$type %||% "",
          status   = j$status %||% "",
          progress = sprintf("%.0f%%", (j$progress %||% 0) * 100),
          created  = format(as.POSIXct(j$created_at %||% 0, origin = "1970-01-01"),
                            "%Y-%m-%d %H:%M:%S"),
          updated  = format(as.POSIXct(j$updated_at %||% 0, origin = "1970-01-01"),
                            "%Y-%m-%d %H:%M:%S"),
          file     = j$result$filename %||% j$result$checkpoint %||% "",
          error    = j$error %||% "",
          log      = last_log,
          stringsAsFactors = FALSE
        )
      }))
      DT::datatable(df, rownames = FALSE, selection = "single",
                    options = list(pageLength = 15, scrollX = TRUE,
                                   order = list(list(4, "desc")))) |>
        DT::formatStyle("status",
          backgroundColor = DT::styleEqual(
            c("completed", "failed",  "running", "cancelled"),
            c("#c8e6c9",   "#ffcdd2", "#bbdefb", "#eeeeee")
          ),
          color = DT::styleEqual(
            c("completed", "failed",  "running", "cancelled"),
            c("#1b5e20",   "#b71c1c", "#0d47a1", "#424242")
          ),
          fontWeight = "bold"
        )
    }, server = FALSE)

    output$tr_job_log_detail <- shiny::renderText({
      sel <- input$tr_jobs_table_rows_selected
      if (is.null(sel) || length(sel) == 0)
        return("Выберите строку для просмотра лога.")
      jobs <- tr_jobs_data()
      if (length(jobs) == 0 || sel > length(jobs)) return("")
      job <- jobs[[sel]]
      log_lines <- job$log %||% list()
      err       <- job$error %||% ""
      out <- character(0)
      if (nzchar(err)) out <- c(out, paste0("[ERROR] ", err))
      if (length(log_lines) > 0) out <- c(out, unlist(log_lines))
      if (length(out) == 0) return("(лог пуст)")
      paste(tail(out, 100), collapse = "\n")
    })

    # ---- Настройки ----
    output$settings_info <- shiny::renderPrint({
      cat("CYBERARXIV_DB_PATH =", Sys.getenv("CYBERARXIV_DB_PATH", "<не задан>"), "\n")
      cat("ML_SERVICE_URL     =", ml_service_url, "\n")
      cat("MODELS_DIR         =",
          Sys.getenv("MODELS_DIR", "/srv/cyberarxiv-ml/models"), "\n")
      cat("Рабочая директория =", getwd(), "\n")
      cat("R:", R.version.string, "\n\n")
      cat("Коллекторы:\n")
      if (!is.null(collectors_df) && nrow(collectors_df) > 0) {
        for (i in seq_len(nrow(collectors_df))) {
          cat(sprintf("  [%s] %-20s %s\n",
              if (collectors_df$enabled[i]) "on " else "off",
              collectors_df$name[i], collectors_df$type[i]))
        }
      } else cat("  (не найдено)\n")
    })
    shiny::observeEvent(input$btn_reinit_db, {
      res <- tryCatch({
        db_path <- Sys.getenv("CYBERARXIV_DB_PATH", "data/cyberarxiv.duckdb")
        dir.create(dirname(db_path), showWarnings = FALSE, recursive = TRUE)
        con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path)
        on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
        .cyberarxiv_init_schema(con)
        "Схема инициализирована."
      }, error = function(e) paste("ERROR:", conditionMessage(e)))
      settings_log_text(res)
      reload_publications()
    })
    output$settings_log <- shiny::renderText({ settings_log_text() })

    # ---- Удаление статей ----
    # Обновить доступные теги и источники при смене данных
    shiny::observe({
      df <- publications()
      if (is.null(df) || nrow(df) == 0) return()
      if ("tag" %in% names(df)) {
        tags <- sort(unique(df$tag[!is.na(df$tag) & nzchar(df$tag)]))
        shiny::updateSelectizeInput(session, "del_tags", choices = tags)
      }
      if ("source" %in% names(df)) {
        srcs <- sort(unique(df$source[!is.na(df$source) & nzchar(df$source)]))
        shiny::updateSelectInput(session, "del_source",
                                 choices = c("Все источники" = "", setNames(srcs, srcs)))
      }
    })

    # Показать сколько статей будет удалено
    output$del_preview <- shiny::renderText({
      df   <- publications()
      tags <- input$del_tags
      src  <- trimws(input$del_source %||% "")
      if (is.null(df) || nrow(df) == 0) return("")
      sub  <- df
      if (length(tags) > 0) sub <- sub[!is.na(sub$tag) & sub$tag %in% tags, ]
      if (nzchar(src))       sub <- sub[!is.na(sub$source) & sub$source == src, ]
      if (nrow(sub) == 0) return("Нет статей под фильтр")
      paste0("Будет удалено: ", nrow(sub), " статей")
    })

    shiny::observeEvent(input$btn_delete_articles, {
      tags <- input$del_tags
      src  <- trimws(input$del_source %||% "")
      if (length(tags) == 0 && !nzchar(src)) {
        output$del_status <- shiny::renderText("Выберите хотя бы один тег или источник.")
        return()
      }
      # Предварительный подсчёт для диалога
      df  <- publications()
      sub <- df
      if (length(tags) > 0) sub <- sub[!is.na(sub$tag) & sub$tag %in% tags, ]
      if (nzchar(src))       sub <- sub[!is.na(sub$source) & sub$source == src, ]
      n_preview <- nrow(sub)

      filter_desc <- character(0)
      if (length(tags) > 0) filter_desc <- c(filter_desc, paste("тег:", paste(tags, collapse = ", ")))
      if (nzchar(src))       filter_desc <- c(filter_desc, paste("источник:", src))

      shiny::showModal(shiny::modalDialog(
        title = "Подтверждение удаления",
        shiny::p(paste0("Будет удалено ", n_preview, " статей:")),
        shiny::p(paste(filter_desc, collapse = " | ")),
        shiny::p(shiny::strong("Это действие необратимо.")),
        footer = shiny::tagList(
          shiny::modalButton("Отмена"),
          shiny::actionButton("btn_delete_confirm", "Удалить", class = "btn-danger")
        ),
        easyClose = TRUE
      ))
    })

    shiny::observeEvent(input$btn_delete_confirm, {
      shiny::removeModal()
      tags <- input$del_tags
      src  <- trimws(input$del_source %||% "")

      res <- tryCatch({
        con <- .cyberarxiv_connect()
        on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

        where  <- character(0)
        params <- list()

        if (length(tags) > 0) {
          where  <- c(where, paste0("tag IN (", paste(rep("?", length(tags)), collapse = ","), ")"))
          params <- c(params, as.list(tags))
        }
        if (nzchar(src)) {
          where  <- c(where, "source = ?")
          params <- c(params, list(src))
        }

        sql <- paste0("DELETE FROM papers WHERE ", paste(where, collapse = " AND "))
        n   <- DBI::dbExecute(con, sql, params = params)
        paste0("Удалено ", n, " статей.")
      }, error = function(e) paste("ERROR:", conditionMessage(e)))

      settings_log_text(res)
      reload_publications()
    })
  }
}

# ============================================================
#  Utils
# ============================================================

`%||%` <- function(a, b) if (is.null(a) || (is.atomic(a) && length(a) == 0)) b else a
