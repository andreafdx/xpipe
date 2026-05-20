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

# Profile registry --------------------------------------------------------

# Profile: SDO Tracciato A+B (+C+D)
.xml_profile_sdo_tracciato_abcd <- function(doc, path, ctx) {
  root_name <- xml2::xml_name(xml2::xml_root(doc))

  if (root_name == "flsaInformazioniAnagrafiche") {
    .log_debug("Detected Tracciato A schema.")
    return(list(anagrafica = .parse_tracciato_a(doc)))
  }

  if (root_name == "flsbInformazioniRicovero") {
    .log_debug("Detected Tracciato B schema.")
    return(.parse_tracciato_b(doc))
  }

  cli::cli_abort(
    c(
      "Unrecognized SDO XML schema",
      "x" = "File {.file {basename(path)}} has unknown root node: {.val {root_name}}"
    ),
    class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
  )
}


# XML profile registry (code-driven)
.xml_profile_registry <- list(
  sdo_tracciato_abcd = .xml_profile_sdo_tracciato_abcd
)

# Internal API ------------------------------------------------------------


#' Extract XML Data (Profile Dispatcher)
#' @export
#' @keywords internal
extract_xml <- function(ctx) {
  checkmate::assert_list(ctx)

  profile <- ctx$method_config$xml_profile %||% NA_character_
  if (!checkmate::test_string(profile, min.chars = 1)) {
    cli::cli_abort(
      c(
        "Invalid method configuration",
        "x" = "Missing {.field xml_profile} for XML method {.val {ctx$method_id}}"
      ),
      class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
    )
  }

  parser <- .xml_profile_registry[[profile]] %||% NULL
  if (is.null(parser) || !is.function(parser)) {
    cli::cli_abort(
      c(
        "Unknown XML profile",
        "x" = "No parser registered for profile {.val {profile}}",
        "i" = "Registered profiles: {.val {names(.xml_profile_registry)}}"
      ),
      class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
    )
  }

  paths <- unique(as.character(unlist(ctx$resolved_inputs)))
  if (length(paths) == 0) {
    paths <- ctx$filepath
  }

  # accumulate per-table outputs across multiple XML files
  acc <- list()

  for (path in paths) {
    cli::cli_inform("Reading XML document: {.file {basename(path)}}")
    doc <- xml2::read_xml(path)

    res <- parser(doc, path, ctx)

    for (nm in names(res)) {
      if (is.null(acc[[nm]])) {
        acc[[nm]] <- res[[nm]]
      } else {
        acc[[nm]] <- .rbind_fill_dfs(list(acc[[nm]], res[[nm]]))
      }
    }
  }

  acc
}



# Helpers ----------------------------------------------------------------

#' Schema-safe row binder (base R)
#'
#' Binds a list of named lists into a data.frame, aligning schemas safely.
#' This is the *canonical* version: predictable, dependency-free, and correct.
#'
#' @param rows List of named lists (each list represents one row)
#' @return data.frame with aligned columns
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

# Bind data.frames preserving list-columns, aligning missing columns
.rbind_fill_dfs <- function(dfs) {
  dfs <- dfs[!vapply(dfs, is.null, logical(1))]
  if (length(dfs) == 0) return(NULL)
  if (length(dfs) == 1) return(dfs[[1]])

  all_cols <- unique(unlist(lapply(dfs, names)))
  dfs2 <- lapply(dfs, function(d) {
    missing <- setdiff(all_cols, names(d))
    if (length(missing) > 0) {
      for (m in missing) d[[m]] <- NA
    }
    d[all_cols]
  })
  do.call(rbind, dfs2)
}



# SDO ---------------------------------------------------------------------



## Tracciato A -------------------------------------------------------------

#' Parse Tracciato A XML document
#'
#' @param doc xml2::xml_document
#' @return data.frame
#' @noRd
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

## Tracciato B -------------------------------------------------------------

#' Parse ricovero row (1:1)
#'
#' @param ctx Record context
#' @return named list
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
#' @noRd
.parse_b_diagnosi <- function(ctx) {

  out <- list()
  codice <- ctx$codice
  prog   <- ctx$prog

  .normalize_diagnosi_cols <- function(nm) {
    nm <- sub("^diagnosiPrincipaleDimissioneAlRicovero$", "presenteAlRicovero", nm)
    nm <- sub("^diagnosiSecondarieDimissioneAlRicovero$", "presenteAlRicovero", nm)
    nm <- sub("^diagnosiPrincipaleDimissione$", "diagnosiDimissione", nm)
    nm <- sub("^diagnosiSecondarieDimissione$", "diagnosiDimissione", nm)
    nm
  }


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
      nms <- xml2::xml_name(ch[is_scalar])
      nms <- vapply(nms, .normalize_diagnosi_cols, character(1))
      row[nms] <- as.list(xml2::xml_text(ch[is_scalar]))
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
        nms <- xml2::xml_name(ch[is_scalar])
        nms <- vapply(nms, .normalize_diagnosi_cols, character(1))
        row[nms] <- as.list(xml2::xml_text(ch[is_scalar]))
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
#' @noRd
.parse_b_procedure <- function(ctx) {

  out <- list()
  codice <- ctx$codice
  prog   <- ctx$prog

  .normalize_proc_cols <- function(nm) {
    nm <- sub("^dataInterventoPrincipale", "dataIntervento", nm)
    nm <- sub("^dataInterventoSecondario", "dataIntervento", nm)
    nm <- sub("^oraInterventoPrincipale", "oraIntervento", nm)
    nm <- sub("^oraInizioInterventoSecondario", "oraIntervento", nm)
    nm <- sub("^chirurgoInterventoPrincipale", "chirurgoIntervento", nm)
    nm <- sub("^chirurgoInterventoSecondario", "chirurgoIntervento", nm)
    nm <- sub("^anestesistaInterventoPrincipale", "anestesistaIntervento", nm)
    nm <- sub("^anestesistaInterventoSecondario", "anestesistaIntervento", nm)
    nm <- sub("^ckListSalaOperatoriaInterventoPrincipale", "ckListSalaOperatoriaIntervento", nm)
    nm <- sub("^ckListSalaOperatoriaInterventoSecondario", "ckListSalaOperatoriaIntervento", nm)
    nm <- sub("^interventoPrincipaleEsterno$", "interventoEsterno", nm)
    nm <- sub("^interventiSecondariEsterni$", "interventoEsterno", nm)
    nm <- sub("^interventoPrincipale", "intervento", nm)
    nm <- sub("^interventiSecondari", "intervento", nm)
    nm
  }

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
      vals <- xml2::xml_text(ch[is_scalar])
      nms  <- vapply(xml2::xml_name(ch[is_scalar]), .normalize_proc_cols, character(1))

      multi_cols <- c("chirurgoIntervento", "anestesistaIntervento")

      for (nm in unique(nms)) {
        vv <- vals[nms == nm]

        if (nm %in% multi_cols) {
          # sempre list-column, anche se length 1
          row[[nm]] <- list(vv)
        } else {
          # scalare: se ci sono più valori qui è un input sporco → abort
          if (length(vv) > 1) {
            cli::cli_abort(
              c(
                "Unexpected repeated scalar field in procedure",
                "x" = sprintf("Field %s appears %d times in one procedure row", nm, length(vv))
              ),
              class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
            )
          }
          row[[nm]] <- if (length(vv) == 0) NA_character_ else vv[[1]]
        }
      }
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
        vals <- xml2::xml_text(ch[is_scalar])
        nms  <- vapply(xml2::xml_name(ch[is_scalar]), .normalize_proc_cols, character(1))

        multi_cols <- c("chirurgoIntervento", "anestesistaIntervento")  # UDI resta scalare

        for (nm in unique(nms)) {
          vv <- vals[nms == nm]

          if (nm %in% multi_cols) {
            row[[nm]] <- list(vv)  # list-column
          } else {
            if (length(vv) > 1) {
              cli::cli_abort(
                c(
                  "Unexpected repeated scalar field in procedure",
                  "x" = sprintf("Field %s appears %d times in one procedure row", nm, length(vv))
                ),
                class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
              )
            }
            row[[nm]] <- if (length(vv) == 0) NA_character_ else vv[[1]]
          }
        }
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

#' Parse transfer rows (0–N)
#'
#' @param ctx Record context
#' @return list of named lists
#' @noRd
.parse_b_trasferimenti <- function(ctx) {

  out <- list()
  codice <- ctx$codice
  prog   <- ctx$prog

  trs <- ctx$info_children[ctx$info_names == "Trasferimenti"]
  if (length(trs) == 0) return(out)

  for (node in trs) {
    num <- xml2::xml_attr(node, "numTrasferimento")
    num <- if (!is.na(num)) as.integer(num) else NA_integer_

    ch <- xml2::xml_children(node)
    is_scalar <- xml2::xml_length(ch) == 0
    if (!any(is_scalar)) next

    row <- list(
      codiceIstitutoDiCura = codice,
      progressivoSDO       = prog,
      numTrasferimento     = num
    )

    row[xml2::xml_name(ch[is_scalar])] <-
      as.list(xml2::xml_text(ch[is_scalar]))

    out[[length(out) + 1]] <- row
  }

  out
}

#' Parse Tracciato B XML document
#'
#' Top-level dispatcher for Tracciato B batch extraction.
#'
#' @param doc xml2::xml_document
#' @return list of data frames
#' @export
.parse_tracciato_b <- function(doc) {

  records <- xml2::xml_find_all(doc, ".//bInformazioniRicovero")
  n <- length(records)

  rows_ricovero   <- vector("list", n)
  rows_diagnosi   <- vector("list", n * 3)
  rows_procedure  <- vector("list", n * 2)
  rows_accessi_dh <- vector("list", n)
  rows_trasferimenti <- vector("list", n * 2)

  kr <- kd <- kp <- kdh <- kt <- 0

  for (rec in records) {
    tryCatch({
      ctx <- .get_record_context(rec)

      ricovero_row <- .parse_b_ricovero(ctx)
      diagnosi_rows <- .parse_b_diagnosi(ctx)
      procedure_rows <- .parse_b_procedure(ctx)
      accessi_rows <- .parse_b_accessi_dh(ctx)
      trasf_rows <- .parse_b_trasferimenti(ctx)

      kr <- kr + 1
      rows_ricovero[[kr]] <- ricovero_row

      for (row in diagnosi_rows)  { kd  <- kd  + 1; rows_diagnosi[[kd]]   <- row }
      for (row in procedure_rows) { kp  <- kp  + 1; rows_procedure[[kp]]  <- row }
      for (row in accessi_rows)   { kdh <- kdh + 1; rows_accessi_dh[[kdh]] <- row }
      for (row in trasf_rows)     { kt  <- kt  + 1; rows_trasferimenti[[kt]] <- row}

    }, error = function(e) {
      cli::cli_warn("Skipping malformed record: {conditionMessage(e)}")
    })
  }

  list(
    ricovero   = .bind_rows_fast(rows_ricovero[seq_len(kr)]),
    diagnosi   = .bind_rows_fast(rows_diagnosi[seq_len(kd)]),
    procedure  = .bind_rows_fast(rows_procedure[seq_len(kp)]),
    accessi_dh = .bind_rows_fast(rows_accessi_dh[seq_len(kdh)]),
    trasferimenti = .bind_rows_fast(rows_trasferimenti[seq_len(kt)])
  )
}
