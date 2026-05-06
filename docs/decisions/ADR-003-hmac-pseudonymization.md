# ADR-003: HMAC-SHA256 with Runtime Pepper for PHI Pseudonymization

**Date**: 2026-04-01 (approx.)
**Status**: Accepted
**Decider**: Andrea Fidecicchi

## Context

The pipeline ingests data containing Protected Health Information (PHI),
primarily patient and encounter identifiers. PHI must not appear in any
persisted layer. The pseudonymization approach must:

1. Be deterministic (same input → same output, for cross-batch joining)
2. Be one-way (re-identification must require the key)
3. Not require persistent key storage
4. Produce stable, fixed-length output suitable for joining

## Decision

Use HMAC-SHA256 keyed by a runtime-only secret (`XNE_PEPPER_KEY`):

- Input is normalized (uppercase + trimmed) before hashing
- The key is loaded from the environment variable at startup and never
  written to disk, logs, or metadata
- `NA` and empty strings produce `NA_character_`, not a hash

## Alternatives Considered

- **Deterministic encryption (AES)**: reversible with the key, which
  may be required for re-identification requests. However, it introduces
  key management complexity (IV handling, padding) for what is effectively
  a one-way operation in this pipeline. Not chosen.
- **SHA-256 without a key (plain hash)**: deterministic but vulnerable
  to dictionary attacks over the known identifier space (e.g. all valid
  Italian fiscal codes can be pre-computed). Not chosen.

## Consequences

- Pseudonymization is deterministic: the same identifier with the same
  pepper produces the same hash in every batch, enabling cross-batch joins.
- Re-identification resistance depends entirely on the secrecy of the
  pepper key. A leaked key allows dictionary attacks over known identifier
  spaces.
- Pepper rotation invalidates all existing hashes. Re-ingestion from
  source is required for consistency after a rotation.
- The pipeline has no awareness of re-identification requests; these must
  be handled operationally (access to the source system).
- `NA` propagation means that missing identifiers are preserved as missing
  rather than silently hashed — a deliberate choice for data integrity.
