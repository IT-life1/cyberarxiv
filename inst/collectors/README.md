# Collector Specs

Each `.yml` file in this directory describes one data source. Drop a file here (or in `~/.cyberarxiv/collectors/`) and it will be picked up automatically.

## Minimal example (RSS)

```yaml
name: my_blog
type: rss
url: "https://example.com/security.rss"
id_prefix: "myblog:"
```

## Minimal example (Atom)

```yaml
name: my_atom
type: atom
url: "https://example.com/atom.xml"
id_prefix: "myatom:"
```

## All supported fields

```yaml
name: source_name          # required: unique identifier used as 'source' in DB
label: "Human Name"        # optional: shown in list_collectors() (default: name)
type: rss                  # required: rss | atom | oai_pmh | json_api | r_script
enabled: true              # optional: set false to skip (default: true)
id_prefix: "prefix:"      # optional: prepended to every ID for global uniqueness

url: "https://..."         # required for rss/atom/oai_pmh

pagination:                # optional
  type: none               # none | offset | page
  start_param: start       # param name for offset
  size_param: max_results  # param name for page size
  page_size: 100

params:                    # optional: static query params appended to URL
  key: value

rate_limit_secs: 1.0       # optional: seconds to sleep between pages (default 1.0)
retry: 3                   # optional: HTTP retry count (default 3)

# Field mapping (for rss): standard_name -> rss_element_name
# Defaults for RSS: id=guid, title=title, abstract=description, link=link, published_date=pubDate
fields:
  id: guid
  title: title
  abstract: description
  link: link
  published_date: pubDate
  authors: "dc:creator"    # optional

# Field mapping (for atom): standard_name -> {xpath, multi, join, attr}
# Defaults cover standard Atom format; override only if needed.
fields:
  id:
    xpath: "./atom:id"
    multi: false
  authors:
    xpath: "./atom:author/atom:name"
    multi: true
    join: "; "

transforms:                # optional: apply built-in transform to a field
  abstract: strip_html     # strip_html | strip_arxiv_id | map_arxiv_categories | identity

# OAI-PMH specific (type: oai_pmh only)
oai:
  metadata_prefix: oai_dc
  set: ""                  # OAI set name; empty = all records

filter_keywords:           # optional: keep only records matching any keyword (case-insensitive)
  - security
  - vulnerability
```

## Custom R script collector

```yaml
name: my_custom
type: r_script
script: "my_custom.R"     # path relative to this YAML file
id_prefix: "custom:"
```

`my_custom.R` must define:

```r
collect <- function(max_results = 100, ...) {
  # Fetch data from your source
  # Return a data.frame with these columns (all character):
  #   id, link, title, authors, abstract, categories, published_date, updated_date
  data.frame(
    id             = "...",
    link           = "...",
    title          = "...",
    authors        = "",        # semicolon-separated, or empty
    abstract       = "...",
    categories     = "",        # semicolon-separated, or empty
    published_date = "2024-01-15T00:00:00Z",
    updated_date   = "2024-01-15T00:00:00Z",
    stringsAsFactors = FALSE
  )
}
```

## JSON API collector (type: json_api)

Generic REST JSON API collector. Configure everything in YAML — no R code needed.

```yaml
name: my_api_source
type: json_api
id_prefix: "myapi:"
base_url: "https://api.example.com/v1"
endpoint: "/articles"

auth:
  type: bearer             # bearer | header | query_param
  token: "YOUR_API_KEY"
  # header_name: "X-API-Key"  # for type: header
  # param_name: "apikey"      # for type: query_param

pagination:
  type: offset             # offset | cursor | page
  limit_param: "limit"
  offset_param: "offset"
  page_size: 20
  # skip_zero_offset: true # set true if API rejects offset=0
  # cursor_path: "meta.next"  # for type: cursor
  # cursor_param: "cursor"    # for type: cursor
  # page_param: "page"        # for type: page
  # start_page: 1             # for type: page

rate_limit_secs: 1.0

query:
  params:
    q: "search terms"
    sort: "date"

response:
  results_path: "data.articles"  # dot-path to results array
  total_path: "meta.total"       # dot-path to total count (optional)

field_map:
  id: "article_id"
  title: "title"
  abstract: "summary"
  link: "url"
  authors: "contributors[].name"  # array of objects -> join with ", "
  published_date: "pub_date"
  categories: "tags[]"            # array of scalars -> join with ", "
```

### Field mapping syntax

| Pattern | Meaning | Example |
|---------|---------|---------|
| `"field"` | Top-level field | `"title"` |
| `"a.b.c"` | Nested field | `"meta.pub_date"` |
| `"arr[].field"` | Array of objects, extract field, join with `, ` | `"authors[].name"` |
| `"arr[]"` | Array of scalars, join with `, ` | `"tags[]"` |

If a field is not found in the response, the value is set to `NA` (not an error).

## Discovery order

1. Built-in: `inst/collectors/` (package defaults)
2. User global: `~/.cyberarxiv/collectors/`
3. Env var: `CYBERARXIV_COLLECTORS_DIR`
4. Programmatic: `extra_dirs` argument in `collect_all()`

A spec with the same `name` in a later directory overrides an earlier one.

## ID normalisation

Every collector output goes through `.standardize_collector_output()` in `R/collector_registry.R`.
Paper IDs are normalised as follows:

| Input ID | Result |
|----------|--------|
| URL (starts with `http://` or `https://`) | `{id_prefix}{sha256(url)}` — compact, stable, collision-free |
| Non-URL (arXiv `2401.12345`, CORE numeric `98765432`) | `{id_prefix}{id}` — unchanged |

This means two different URLs always produce different IDs, but the same URL always
produces the same ID regardless of when it was fetched.

**Example:** a КиберЛенинка article `https://cyberleninka.ru/article/n/test` with
`id_prefix: "cln:"` → `cln:a3f2...` (first 64 hex chars of SHA-256).

## Language detection

Language is auto-detected from the concatenation of `title + " " + abstract`.
If the ratio of Cyrillic characters exceeds 25%, the paper is tagged `"ru"`.
Otherwise it defaults to `"en"`.

The YAML `language:` field serves as a **fallback only** — it is used when
`title` and `abstract` are both empty (common for OAI-PMH records without a
`dc:description`).

To force a language for all records from a collector, set:

```yaml
language: ru
```

## Troubleshooting

### arXiv (type: atom)

**Problem:** Fewer results than `max_results`.
arXiv imposes a server-side cap of 2000 results per query. Large requests are
silently truncated. Split into multiple date-ranged queries if you need more.

**Problem:** `403 Forbidden` after many requests.
arXiv rate-limits aggressive crawlers. Set `rate_limit_secs: 3` or higher.

### CORE (type: json_api)

**Problem:** `HTTP 500` when adding `offset=0`.
CORE REST API v3 free tier rejects `offset=0`. Set `skip_zero_offset: true` in
the `pagination:` section of the YAML. The built-in `core.yml` already does this.

**Problem:** Fewer than `page_size` results despite many matching papers.
CORE uses Elasticsearch under the hood; the free tier caps at 10 per request and
total result sets are often smaller than the `totalHits` counter suggests.
CORE is best used as a supplemental source, not primary.

**Problem:** `401 Unauthorized`.
The `auth.token` in `core.yml` has expired or is incorrect. Generate a new key at
`https://core.ac.uk/` and update `core.yml`.

### КиберЛенинка (type: oai_pmh)

**Problem:** `<record>` elements are invisible / collector returns 0 papers.
OAI-PMH responses use a default XML namespace (`xmlns="http://..."`). XPath
queries must use the `oai:` prefix — e.g. `oai:record`, not `record`.
This is handled internally; do not remove the `oai:` prefix from field XPaths.

**Problem:** `published_date` is missing for some records.
КиберЛенинка often omits `dc:date`. The collector falls back to the OAI-PMH
`datestamp` field in the `<header>`. If that too is missing, the date is `NA`.

**Problem:** `max_pages` is ignored and all pages are fetched.
Set `max_pages:` at the top level of the YAML (not inside `oai:`):

```yaml
name: cyberleninka
type: oai_pmh
max_pages: 10
```

**Problem:** `oai_from` date filter not working.
The `oai_from` field maps to the OAI-PMH `from` parameter (ISO-8601 date,
e.g. `2024-01-01`). Check that the server supports selective harvesting by
verifying `<granularity>` in the `Identify` response.

### Custom R script (type: r_script)

**Problem:** `collect()` not found.
The R script must define a function named exactly `collect` (not `Collect`,
not `fetch_data`). The registry calls `collect(max_results = n)`.

**Problem:** Missing columns cause downstream errors.
The function must return all 8 standard columns:
`id, link, title, authors, abstract, categories, published_date, updated_date`.
Missing columns are not auto-filled — the collector will fail schema validation.
