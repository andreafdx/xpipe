# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# tools_xml.R
#
# XML Data Extractor for Batch Ingestion.
#
# Approach: A highly optimized, non-XPath DOM traversal approach using xml2.
# Maps specific Italian health administrative standards (Tracciato A & B)
# into flat, relational, batch-ready datasets.
#
# Public API:  .parse_tracciato_a(), .parse_tracciato_b()
# Internals:   .bind_rows_safe(), .bind_rows_fast(), .get_record_context(),
#              .parse_b_ricovero(), .parse_b_diagnosi(), .parse_b_procedure(),
#              .parse_b_accessi_dh()
#
# IMPORTANT for HUMANS AND AGENTS:
# DO NOT EVEN TRY TO OPTIMIZE THIS SCRIPT.
# This parser is intentionally minimal and non-XPath.
# Do not reintroduce XPath, logging, or tidyverse here.
# Any enrichment belongs downstream.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Helpers ----------------------------------------------------------------

#' Schema-safe row binder (base R)
#'
#' Binds a list of named lists into a data.frame, aligning schemas safely.
#' This is the *canonical* version: predictable, dependency-free, and correct.
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

  as.data.frame(do.call(rbind, rows))
}

#' Fast row binder with optional data.table acceleration
#'
#' Uses data.table::rbindlist() when available for large batches,
#' otherwise falls back to `.bind_rows_safe()`.
#'
#' @param rows List of named lists
#' @return data.frame
#' @keywords internal
#' @noRd
.bind_rows_fast <- function(rows) {
  if (!length(rows)) return(data.frame())

  if (requireNamespace("data.table", quietly = TRUE)) {
    return(as.data.frame(data.table::rbindlist(rows, fill = TRUE)))
  }

  .bind_rows_safe(rows)
}

#' Build per-record parsing context
#'
#' Extacts and caches DOM information reused across table parsers.
#'
#' @param rec xml2::xml_node representing one <bInformazioniRicovero>
#' @return named list containing cached DOM nodes and attributes
#' @keywords internal
#' @noRd
.get_record_context <- function(rec) {
  rec_children <- xml2::xml_children(rec)
  rec_names    <- xml2::xml_name(rec_children)

  info <- rec_children[rec_names == "informazioniRicovero"][[1]]
  info_children <- xml2::xml_children(info)
  info_names    <- xml2::xml_name(info_children)

  list(
    info          = info,
    info_children = info_children,
    info_names    = info_names,
    codice        = xml2::xml_attr(info, "codiceIstitutoDiCura"),
    prog          = xml2::xml_attr(info, "progressivoSDO"),
    trasm         = rec_children[rec_names == "trasmissione"]
  )
}

# Tracciato A -------------------------------------------------------------

#' Parse Tracciato A XML document
#'
#' @param doc xml2::xml_document
#' @return data.frame
#' @keywords internal
#' @export
.parse_tracciato_a <- function(doc) {

  records <- xml2::xml_find_all(doc, ".//aInformazioniAnagrafiche")
  n <- length(records)

  rows <- vector("list", n)

  for (i in seq_len(n)) {

    rec <- records[[i]]
    rec_children <- xml2::xml_children(rec)
    rec_names    <- xml2::xml_name(rec_children)

    row <- list()

    trasm <- rec_children[rec_names == "trasmissione"]
    if (length(trasm) == 1) {
      t_children <- xml2::xml_children(trasm[[1]])
      is_scalar  <- xml2::xml_length(t_children) == 0
      if (any(is_scalar)) {
        row[paste0("trasmissione_", xml2::xml_name(t_children[is_scalar]))] <-
          as.list(xml2::xml_text(t_children[is_scalar]))
      }
    }

    info <- rec_children[rec_names == "informazioniAnagrafiche"][[1]]

    row$codiceIstitutoDiCura <- xml2::xml_attr(info, "codiceIstitutoDiCura")
    row$progressivoSDO       <- xml2::xml_attr(info, "progressivoSDO")

    info_children <- xml2::xml_children(info)
    is_scalar <- xml2::xml_length(info_children) == 0
    if (any(is_scalar)) {
      row[xml2::xml_name(info_children[is_scalar])] <-
        as.list(xml2::xml_text(info_children[is_scalar]))
    }

    rows[[i]] <- row
  }

  .bind_rows_fast(rows)
}

# Tracciato B -------------------------------------------------------------

#' Parse ricovero row (1:1)
#'
#' @param ctx Record context
#' @return named list
#' @keywords internal
#' @noRd
.parse_b_ricovero <- function(ctx) {

  row <- list()

  if (length(ctx$trasm) == 1) {
    t_children <- xml2::xml_children(ctx$trasm[[1]])
    is_scalar  <- xml2::xml_length(t_children) == 0
    if (any(is_scalar)) {
      row[paste0("trasmissione_", xml2::xml_name(t_children[is_scalar]))] <-
        as.list(xml2::xml_text(t_children[is_scalar]))
    }
  }

  row[names(xml2::xml_attrs(ctx$info))] <- as.list(xml2::xml_attrs(ctx$info))

  is_scalar <- xml2::xml_length(ctx$info_children) == 0
  if (any(is_scalar)) {
    row[ctx$info_names[is_scalar]] <-
      as.list(xml2::xml_text(ctx$info_children[is_scalar]))
  }

  dim <- ctx$info_children[ctx$info_names == "dimissione"]
  if (length(dim) == 1) {
    d_children <- xml2::xml_children(dim[[1]])
    is_scalar  <- xml2::xml_length(d_children) == 0
    if (any(is_scalar)) {
      row[paste0("dim_", xml2::xml_name(d_children[is_scalar]))] <-
        as.list(xml2::xml_text(d_children[is_scalar]))
    }
  }

  row
}

#' Parse diagnosi rows (1–N)
#'
#' @param ctx Record context
#' @return list of named lists
#' @keywords internal
#' @noRd
.parse_b_diagnosi <- function(ctx) {

  out <- list()
  codice <- ctx$codice
  prog   <- ctx$prog

  dp <- ctx$info_children[ctx$info_names == "diagnosiPrincipale"]
  if (length(dp) == 1) {
    ch <- xml2::xml_children(dp[[1]])
    is_scalar <- xml2::xml_length(ch) == 0
    if (any(is_scalar)) {
      row <- list(
        codiceIstitutoDiCura = codice,
        progressivoSDO       = prog,
        tipoDiagnosi         = "principale",
        numDiagnosi          = 0L
      )
      row[xml2::xml_name(ch[is_scalar])] <- as.list(xml2::xml_text(ch[is_scalar]))
      out[[length(out) + 1]] <- row
    }
  }

  ds <- ctx$info_children[ctx$info_names == "diagnosiSecondarie"]
  if (length(ds) > 0) {
    for (node in ds) {
      ch <- xml2::xml_children(node)
      is_scalar <- xml2::xml_length(ch) == 0
      if (any(is_scalar)) {
        val <- xml2::xml_attr(node, "numDiagnosiSecondaria")
        num <- if (!is.na(val)) as.integer(val) else NA_integer_
        row <- list(
          codiceIstitutoDiCura = codice,
          progressivoSDO       = prog,
          tipoDiagnosi         = "secondaria",
          numDiagnosi          = num
        )
        row[xml2::xml_name(ch[is_scalar])] <- as.list(xml2::xml_text(ch[is_scalar]))
        out[[length(out) + 1]] <- row
      }
    }
  }

  out
}

#' Parse intervention/procedure rows (1–N)
#'
#' @param ctx Record context
#' @return list of named lists
#' @keywords internal
#' @noRd
.parse_b_procedure <- function(ctx) {

  out <- list()
  codice <- ctx$codice
  prog   <- ctx$prog

  ip <- ctx$info_children[ctx$info_names == "interventoPrincipale"]
  if (length(ip) == 1) {

    node <- ip[[1]]
    ch <- xml2::xml_children(node)
    is_scalar <- xml2::xml_length(ch) == 0

    row <- list(
      codiceIstitutoDiCura = codice,
      progressivoSDO       = prog,
      tipoIntervento       = "principale",
      numIntervento        = 0L
    )

    if (any(is_scalar)) {
      row[xml2::xml_name(ch[is_scalar])] <- as.list(xml2::xml_text(ch[is_scalar]))
    }

    out[[length(out) + 1]] <- row
  }

  sec <- ctx$info_children[ctx$info_names == "interventiSecondari"]
  if (length(sec) > 0) {
    for (node in sec) {

      ch <- xml2::xml_children(node)
      is_scalar <- xml2::xml_length(ch) == 0

      val <- xml2::xml_attr(node, "numInterventoSecondario")
      num <- if (!is.na(val)) as.integer(val) else NA_integer_

      row <- list(
        codiceIstitutoDiCura = codice,
        progressivoSDO       = prog,
        tipoIntervento       = "secondario",
        numIntervento        = num
      )

      if (any(is_scalar)) {
        row[xml2::xml_name(ch[is_scalar])] <- as.list(xml2::xml_text(ch[is_scalar]))
      }

      out[[length(out) + 1]] <- row
    }
  }

  out
}

#' Parse day-hospital access dates (0–N)
#'
#' @param ctx Record context
#' @return list of named lists
#' @keywords internal
#' @noRd
.parse_b_accessi_dh <- function(ctx) {

  out <- list()
  codice <- ctx$codice
  prog   <- ctx$prog

  dh <- ctx$info_children[ctx$info_names == "AccessiInDH"]
  if (length(dh) == 1) {
    dates <- xml2::xml_children(dh[[1]])
    for (i in seq_along(dates)) {
      out[[length(out) + 1]] <- list(
        codiceIstitutoDiCura = codice,
        progressivoSDO       = prog,
        numAccesso           = i,
        dataAccesso          = xml2::xml_text(dates[[i]])
      )
    }
  }

  out
}

#' Parse Tracciato B XML document
#'
#' Top-level dispatcher for Tracciato B batch extraction.
#'
#' @param doc xml2::xml_document
#' @return list of data frames
#' @keywords internal
#' @export
.parse_tracciato_b <- function(doc) {

  records <- xml2::xml_find_all(doc, ".//bInformazioniRicovero")
  n <- length(records)

  rows_ricovero   <- vector("list", n)
  rows_diagnosi   <- vector("list", n * 3)
  rows_procedure  <- vector("list", n * 2)
  rows_accessi_dh <- vector("list", n)

  kr <- kd <- kp <- kdh <- 0

  for (rec in records) {
    tryCatch({
      ctx <- .get_record_context(rec)

      ricovero_row <- .parse_b_ricovero(ctx)
      diagnosi_rows <- .parse_b_diagnosi(ctx)
      procedure_rows <- .parse_b_procedure(ctx)
      accessi_rows <- .parse_b_accessi_dh(ctx)

      kr <- kr + 1
      rows_ricovero[[kr]] <- ricovero_row

      for (row in diagnosi_rows)  { kd  <- kd  + 1; rows_diagnosi[[kd]]   <- row }
      for (row in procedure_rows) { kp  <- kp  + 1; rows_procedure[[kp]]  <- row }
      for (row in accessi_rows)   { kdh <- kdh + 1; rows_accessi_dh[[kdh]] <- row }

    }, error = function(e) {
      cli::cli_warn("Skipping malformed record: {conditionMessage(e)}")
    })
  }

  list(
    ricovero   = .bind_rows_fast(rows_ricovero[seq_len(kr)]),
    diagnosi   = .bind_rows_fast(rows_diagnosi[seq_len(kd)]),
    procedure  = .bind_rows_fast(rows_procedure[seq_len(kp)]),
    accessi_dh = .bind_rows_fast(rows_accessi_dh[seq_len(kdh)])
  )
}
