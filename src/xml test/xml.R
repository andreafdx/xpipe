
  # IMPORTANT for HUMANS AND AGENTS:
  # This parser is intentionally minimal and non-XPath.
  # Do not reintroduce XPath, logging, or tidyverse here.
  # Any enrichment belongs downstream.
  # Do not remove this comment or any other small comment I wrote,
  # I need them even if they look stupid.


# Tracciato A -------------------------------------------------------------
#
# Parses <aInformazioniAnagrafiche> records.
# Each XML record produces exactly one output row.
#
# This parser is intentionally simple:
# - One record → one row
# - No multi-table fan-out
# - No list-columns
#
# Performance notes:
# - XML DOM traversal cost is low for Tracciato A
# - Optimizations focus on reducing repeated xml_name() calls
#   and cleaning schema alignment logic
#

.parse_tracciato_a <- function(doc) {

  records <- xml_find_all(doc, ".//aInformazioniAnagrafiche")
  n <- length(records)

  # Preallocate rows
  rows <- vector("list", n)

  # Main loop: 1 record → 1 row
  for (i in seq_len(n)) {

    rec <- records[[i]]
    rec_children <- xml_children(rec)
    rec_names    <- xml_name(rec_children)

    row <- list()


    # <trasmissione>
    trasm <- rec_children[rec_names == "trasmissione"]
    if (length(trasm) == 1) {
      t_children <- xml_children(trasm[[1]])
      is_scalar  <- xml_length(t_children) == 0
      if (any(is_scalar)) {
        row[paste0("trasmissione_", xml_name(t_children[is_scalar]))] <-
          as.list(xml_text(t_children[is_scalar]))
      }
    }


    # <informazioniAnagrafiche>
    info <- rec_children[rec_names == "informazioniAnagrafiche"][[1]]

    # XML attributes (always present keys)
    row$codiceIstitutoDiCura <- xml_attr(info, "codiceIstitutoDiCura")
    row$progressivoSDO       <- xml_attr(info, "progressivoSDO")

    # Scalar children of informazioniAnagrafiche
    info_children <- xml_children(info)
    is_scalar <- xml_length(info_children) == 0
    if (any(is_scalar)) {
      row[xml_name(info_children[is_scalar])] <-
        as.list(xml_text(info_children[is_scalar]))
    }

    rows[[i]] <- row
  }

  # Schema alignment
  all_names <- unique(unlist(lapply(rows, names)))

  for (i in seq_len(n)) {
    missing <- setdiff(all_names, names(rows[[i]]))
    if (length(missing)) {
      rows[[i]][missing] <- NA_character_
    }
    rows[[i]] <- rows[[i]][all_names]
  }

  as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
}


# Tracciato B -------------------------------------------------------------
#
# Optimized, relational, Batch‑correct XML parser.
#
# Produces four tables:
#   - ricovero
#   - diagnosi
#   - procedure
#   - accessi_dh
#
# Design constraints (DO NOT VIOLATE):
#   - No XPath inside record loops
#   - xml_children()/xml_name() cached once per record
#   - No list‑columns in batch output
#   - Accessi DH is a separate table
#   - Output is stable and append‑safe for Bronze/Silver
#
# PERFORMANCE NOTE
# ~~~~~~~~~~~~~~~~
# This parser is DOM‑bound (libxml2).
# Profiling confirms that remaining cost is dominated by:
#   - xml_nodeset / xml_children traversal
#
# Further performance improvements would require:
#   - a different data format (e.g. CSV, Parquet)
#   - or a non‑DOM parser in another language
#
# Do NOT attempt SAX/streaming in this pipeline.


## Helpers ----------------------------------------------------------------

#' Schema‑safe row binder (base R)
#'
#' Binds a list of named lists into a data.frame, aligning schemas safely.
#' This is the *canonical* version: predictable, dependency‑free, and correct.
#'
#' Performance:
#'   - Fine up to ~50–100k rows
#'   - Switched out automatically by `.bind_rows_fast()` when possible
#'
#' @param rows List of named lists (each list represents one row)
#' @return data.frame with aligned columns
#' @keywords internal
#' @noRd
.bind_rows_safe <- function(rows) {
  if (length(rows) == 0) return(data.frame())

  all_names <- unique(unlist(lapply(rows, names)))
  rows <- lapply(rows, function(r) {
    missing <- setdiff(all_names, names(r))
    if (length(missing)) r[missing] <- NA_character_
    r[all_names]
  })

  as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
}

#' Fast row binder with optional data.table acceleration
#'
#' Uses data.table::rbindlist() when available for large batches,
#' otherwise falls back to `.bind_rows_safe()`.
#'
#' This function is deliberately isolated so performance strategy
#' can be changed without touching parsing logic.
#'
#' @param rows List of named lists
#' @return data.frame
#' @keywords internal
#' @noRd
.bind_rows_fast <- function(rows) {
  if (!length(rows)) return(data.frame())

  if (requireNamespace("data.table", quietly = TRUE)) {
    return(data.table::rbindlist(rows, fill = TRUE))
  }

  .bind_rows_safe(rows)
}



#' Build per‑record parsing context
#'
#' This is a *critical* performance and structure function.
#'
#' It extracts and caches all DOM information that is reused across
#' the four table parsers. This avoids repeated xml_children/xml_name
#' calls and eliminates the largest avoidable XML traversal overhead.
#'
#' @param rec xml2::xml_node representing one <bInformazioniRicovero>
#' @return named list containing cached DOM nodes and attributes
#' @keywords internal
#' @noRd
.get_record_context <- function(rec) {
  rec_children <- xml_children(rec)
  rec_names    <- xml_name(rec_children)

  info <- rec_children[rec_names == "informazioniRicovero"][[1]]
  info_children <- xml_children(info)
  info_names    <- xml_name(info_children)

  list(
    info          = info,
    info_children = info_children,
    info_names    = info_names,
    codice        = xml_attr(info, "codiceIstitutoDiCura"),
    prog          = xml_attr(info, "progressivoSDO"),
    trasm         = rec_children[rec_names == "trasmissione"]
  )
}


## Ricovero (1 row) -------------------------------------------------------

#' Parse ricovero row (1:1)
#'
#' Extracts the main hospitalization record.
#' This includes:
#'   - transmission metadata (flattened)
#'   - attributes of informazioniRicovero
#'   - scalar child fields
#'   - dimissione block (flattened)
#'
#' @param ctx Record context built by .get_record_context()
#' @return named list representing one ricovero row
#' @keywords internal
#' @noRd
.parse_b_ricovero <- function(ctx) {

  row <- list()

  # trasmissione (1‑1, flattened with prefix)
  if (length(ctx$trasm) == 1) {
    t_children <- xml_children(ctx$trasm[[1]])
    is_scalar  <- xml_length(t_children) == 0
    if (any(is_scalar)) {
      row[paste0("trasmissione_", xml_name(t_children[is_scalar]))] <-
        as.list(xml_text(t_children[is_scalar]))
    }
  }

  # attributi informazioniRicovero
  row[names(xml_attrs(ctx$info))] <- as.list(xml_attrs(ctx$info))

  # scalar children
  is_scalar <- xml_length(ctx$info_children) == 0
  if (any(is_scalar)) {
    row[ctx$info_names[is_scalar]] <-
      as.list(xml_text(ctx$info_children[is_scalar]))
  }

  # dimissione (1‑1, flattened)
  dim <- ctx$info_children[ctx$info_names == "dimissione"]
  if (length(dim) == 1) {
    d_children <- xml_children(dim[[1]])
    is_scalar  <- xml_length(d_children) == 0
    if (any(is_scalar)) {
      row[paste0("dim_", xml_name(d_children[is_scalar]))] <-
        as.list(xml_text(d_children[is_scalar]))
    }
  }

  row
}

## Diagnosi ---------------------------------------------------------------

#' Parse diagnosi rows (1–N)
#'
#' Emits:
#'   - exactly one "principale" diagnosis if present
#'   - zero or more "secondaria" diagnoses
#'
#' Each diagnosis becomes a separate relational row.
#'
#' @param ctx Record context
#' @return list of named lists (rows)
#' @keywords internal
#' @noRd
.parse_b_diagnosi <- function(ctx) {

  out <- list()
  codice <- ctx$codice
  prog   <- ctx$prog

  # Diagnosi principale
  dp <- ctx$info_children[ctx$info_names == "diagnosiPrincipale"]
  if (length(dp) == 1) {
    ch <- xml_children(dp[[1]])
    is_scalar <- xml_length(ch) == 0
    if (any(is_scalar)) {
      row <- list(
        codiceIstitutoDiCura = codice,
        progressivoSDO       = prog,
        tipoDiagnosi         = "principale",
        numDiagnosi          = 0L
      )
      row[xml_name(ch[is_scalar])] <- as.list(xml_text(ch[is_scalar]))
      out[[length(out) + 1]] <- row
    }
  }

  # Diagnosi secondarie
  ds <- ctx$info_children[ctx$info_names == "diagnosiSecondarie"]
  if (length(ds) > 0) {
    for (node in ds) {
      ch <- xml_children(node)
      is_scalar <- xml_length(ch) == 0
      if (any(is_scalar)) {
        row <- list(
          codiceIstitutoDiCura = codice,
          progressivoSDO       = prog,
          tipoDiagnosi         = "secondaria",
          numDiagnosi =
            suppressWarnings(as.integer(xml_attr(node, "numDiagnosiSecondaria")))
        )
        row[xml_name(ch[is_scalar])] <- as.list(xml_text(ch[is_scalar]))
        out[[length(out) + 1]] <- row
      }
    }
  }

  out
}


## Procedure --------------------------------------------------------------

#' Parse intervention/procedure rows (1–N)
#'
#' Emits:
#'   - at most one "principale" intervention
#'   - zero or more "secondario" interventions
#'
#' This function is fully inlined for performance.
#'
#' @param ctx Record context
#' @return list of named lists (rows)
#' @keywords internal
#' @noRd
.parse_b_procedure <- function(ctx) {

  out <- list()
  codice <- ctx$codice
  prog   <- ctx$prog

  # Intervento principale
  ip <- ctx$info_children[ctx$info_names == "interventoPrincipale"]
  if (length(ip) == 1) {

    node <- ip[[1]]
    ch <- xml_children(node)
    is_scalar <- xml_length(ch) == 0

    row <- list(
      codiceIstitutoDiCura = codice,
      progressivoSDO       = prog,
      tipoIntervento       = "principale",
      numIntervento        = 0L
    )

    if (any(is_scalar)) {
      row[xml_name(ch[is_scalar])] <- as.list(xml_text(ch[is_scalar]))
    }

    out[[length(out) + 1]] <- row
  }

  # Interventi secondari
  sec <- ctx$info_children[ctx$info_names == "interventiSecondari"]
  if (length(sec) > 0) {
    for (node in sec) {

      ch <- xml_children(node)
      is_scalar <- xml_length(ch) == 0

      val <- xml_attr(node, "numInterventoSecondario")
      num <- if (!is.na(val)) as.integer(val) else NA_integer_

      row <- list(
        codiceIstitutoDiCura = codice,
        progressivoSDO       = prog,
        tipoIntervento       = "secondario",
        numIntervento        = num
      )

      if (any(is_scalar)) {
        row[xml_name(ch[is_scalar])] <- as.list(xml_text(ch[is_scalar]))
      }

      out[[length(out) + 1]] <- row
    }
  }

  out
}


## Accessi DH -------------------------------------------------------------

#' Parse day‑hospital access dates (0–N)
#'
#' Accessi DH are deliberately emitted as a *separate table*
#' to preserve relational integrity and Bronze append safety.
#'
#' @param ctx Record context
#' @return list of named lists (rows)
#' @keywords internal
#' @noRd
.parse_b_accessi_dh <- function(ctx) {

  out <- list()
  codice <- ctx$codice
  prog   <- ctx$prog

  dh <- ctx$info_children[ctx$info_names == "AccessiInDH"]
  if (length(dh) == 1) {
    dates <- xml_children(dh[[1]])
    for (i in seq_along(dates)) {
      out[[length(out) + 1]] <- list(
        codiceIstitutoDiCura = codice,
        progressivoSDO       = prog,
        numAccesso           = i,
        dataAccesso          = xml_text(dates[[i]])
      )
    }
  }

  out
}

## Main parser (Internal API) ---------------------------------------------

#' Parse Tracciato B XML document
#'
#' Top‑level dispatcher for Tracciato B batch extraction.
#' This is the *only* public‑facing function in this file.
#'
#' The function:
#'   - iterates once over <bInformazioniRicovero> records
#'   - builds a shared DOM context per record
#'   - emits four independent relational tables
#'
#' @param doc xml2::xml_document
#' @return list with elements:
#'   - ricovero
#'   - diagnosi
#'   - procedure
#'   - accessi_dh
#' @keywords internal
#' @export
.parse_tracciato_b <- function(doc) {

  records <- xml_find_all(doc, ".//bInformazioniRicovero")
  n <- length(records)

  # preallocation heuristics
  # NOTE: preallocation sizes are heuristics for performance only.
  # Counters + final trimming guarantee correctness regardless of guess accuracy.
  rows_ricovero   <- vector("list", n)
  rows_diagnosi   <- vector("list", n * 3)
  rows_procedure  <- vector("list", n * 2)
  rows_accessi_dh <- vector("list", n)

  kr <- kd <- kp <- kdh <- 0

  for (rec in records) {

    ctx <- .get_record_context(rec)

    kr <- kr + 1
    rows_ricovero[[kr]] <- .parse_b_ricovero(ctx)

    for (row in .parse_b_diagnosi(ctx)) {
      kd <- kd + 1
      rows_diagnosi[[kd]] <- row
    }

    for (row in .parse_b_procedure(ctx)) {
      kp <- kp + 1
      rows_procedure[[kp]] <- row
    }

    for (row in .parse_b_accessi_dh(ctx)) {
      kdh <- kdh + 1
      rows_accessi_dh[[kdh]] <- row
    }
  }

  list(
    ricovero   = .bind_rows_fast(rows_ricovero[seq_len(kr)]),
    diagnosi   = .bind_rows_fast(rows_diagnosi[seq_len(kd)]),
    procedure  = .bind_rows_fast(rows_procedure[seq_len(kp)]),
    accessi_dh = .bind_rows_fast(rows_accessi_dh[seq_len(kdh)])
  )
}
