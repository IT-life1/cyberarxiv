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
type: rss                  # required: rss | atom | oai_pmh | r_script
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

## Discovery order

1. Built-in: `inst/collectors/` (package defaults)
2. User global: `~/.cyberarxiv/collectors/`
3. Env var: `CYBERARXIV_COLLECTORS_DIR`
4. Programmatic: `extra_dirs` argument in `collect_all()`

A spec with the same `name` in a later directory overrides an earlier one.
