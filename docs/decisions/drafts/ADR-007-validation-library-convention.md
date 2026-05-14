# ADR-007: checkmate for Assertions, rlang for Control Flow

**Date**: 2026-05-05
**Status**: Accepted
**Decider**: Andrea Fidecicchi

## Context

The package uses two libraries that overlap in their assertion
capabilities: `rlang` (part of the Tidyverse) and `checkmate` (a
dedicated assertion library). During development, `rlang::check_string`
and `rlang::check_character` were used for internal validation, but
these functions are not exported from `rlang`'s public namespace in
all versions (they exist as "standalone files" intended to be copied
into packages, not called via `rlang::`). This caused namespace errors
at test time.

## Decision

Establish a clear division of responsibility:

- **`checkmate::`** — all type and value assertions
  (`assert_string`, `assert_character`, `assert_class`, `assert_flag`,
  `assert_list`, etc.)
- **`rlang::`** — control flow and R-meta concerns only:
  `check_required()` (detects truly missing arguments, not NULL),
  `try_fetch()`, `caller_env()`, `caller_arg()`
- **`cli::`** — all user-facing error and message formatting via
  `cli_abort`, `cli_alert_*`, `cli_inform`

`rlang::check_required` is kept because it detects a *missing* argument
at the R language level, which `checkmate::assert_not_null` cannot
replicate (NULL is a valid explicit argument, missing is not).

## Alternatives Considered

- **checkmate only**: would lose `check_required()` for missing argument
  detection. Acceptable but slightly less idiomatic for R internals.
- **rlang only**: depends on unexported functions; already caused
  failures. Rejected.
- **base R stopifnot()**: poor error messages, no class hierarchy,
  not compatible with the `xpipe_error` taxonomy. Rejected.

## Consequences

- `rlang` and `checkmate` are both listed in `Imports` in `DESCRIPTION`.
- All assertion code is consistent and will not break across rlang
  version updates.
- Any future contributor must follow this convention; it is documented
  here to avoid re-introducing `rlang::check_*` assertions by mistake.
