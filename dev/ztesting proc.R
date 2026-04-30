library(dplyr)
library(cli)

#' Verifica allineamento Procedura Principale (SDO) vs max(c_Flag) in PRO
#' Vieta rigorosamente i pareggi (ties) sul flag massimo.
#'
#' @param sdo_df Dataframe della tabella SDO
#' @param pro_df Dataframe della tabella PRO
#' @return Un dataframe contenente solo le SDO disallineate
check_allineamento_flag_procedure <- function(sdo_df, pro_df) {

  cli::cli_h1("Controllo Allineamento Procedure Principali (Strict Flag Mode)")

  sdo_con_proc <- sdo_df |>
    filter(!is.na(v_ProceduraPrincipale)) |>
    select(i_IDScheda, v_ProceduraPrincipale)

  confronto <- sdo_con_proc |>
    left_join(pro_df |> select(i_IDScheda, v_CodiceProcedura, c_Flag), by = "i_IDScheda") |>
    group_by(i_IDScheda) |>
    summarize(
      v_ProceduraPrincipale = first(v_ProceduraPrincipale),

      max_flag = suppressWarnings(max(c_Flag, na.rm = TRUE)),

      # Contiamo quante procedure condividono il flag massimo
      n_max_flag = if(is.infinite(max_flag)) 0L else sum(c_Flag == max_flag, na.rm = TRUE),

      codici_max_flag = if(is.infinite(max_flag)) {
        NA_character_
      } else {
        paste(v_CodiceProcedura[c_Flag == max_flag & !is.na(c_Flag)], collapse = ", ")
      },

      .groups = "drop"
    ) |>
    mutate(
      stato = case_when(
        is.infinite(max_flag) ~ "Nessun c_Flag valido (tutti NA)",
        n_max_flag > 1 ~ "Disallineato (Pareggio: multipli record col flag massimo)",
        v_ProceduraPrincipale != codici_max_flag ~ "Disallineato (Codice non coincidente)",
        TRUE ~ "Allineato"
      )
    )

  totale <- nrow(confronto)
  disallineati <- confronto |> filter(stato != "Allineato")
  n_disallineati <- nrow(disallineati)

  cli::cli_bullets(c(
    "SDO totali con procedura princ. : {.val {totale}}",
    "SDO perfettamente allineate     : {.val {totale - n_disallineati}}",
    "SDO disallineate                : {.val {n_disallineati}}"
  ))

  if (n_disallineati > 0) {
    cli::cli_alert_warning("Trovati {n_disallineati} disallineamenti. Restituisco il dataframe per ispezione.")
    print(disallineati |> count(stato))
  } else {
    cli::cli_alert_success("Perfetto! La procedura principale è sempre unica e col c_Flag più alto.")
  }

  invisible(disallineati)
}

# Per eseguirlo:
errori_proc <- check_allineamento_flag_procedure(sdo, pro)
View(errori_proc)



pareggi_flag <- sdo |>
  filter(!is.na(v_ProceduraPrincipale)) |>
  select(i_IDScheda) |>
  inner_join(pro, by = "i_IDScheda") |>
  filter(!is.na(c_Flag)) |>
  group_by(i_IDScheda) |>
  filter(c_Flag == max(c_Flag, na.rm = TRUE)) |>
  count(name = "numero_procedure_al_primo_posto") |>
  filter(numero_procedure_al_primo_posto > 1)

# Quante SDO hanno un pareggio sul flag massimo?
nrow(pareggi_flag)
