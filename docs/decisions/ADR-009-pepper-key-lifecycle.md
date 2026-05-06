# ADR-009: Pepper Key Lifecycle and Distribution

**Date**: 2026-05-06
**Status**: Open — operational policy not yet defined

## Context

The HMAC pepper key (`XNE_PEPPER_KEY`) is the sole secret protecting
the reversibility of all pseudonymized identifiers across every batch
and every Bronze shard ever produced. The pipeline code enforces that
it is never persisted or logged, but it says nothing about:

- How the key is generated
- How it is distributed to operators who need to run the pipeline
- How it is stored securely on operator machines
- What happens when an operator leaves the team
- Whether (and when) it should be rotated

## Open Questions

1. **Generation**: is the key a random 256-bit string? A passphrase? A
   key derived from an institutional secret?

2. **Distribution**: how do new operators receive the key? Via password
   manager (e.g. Bitwarden)? Via institutional IT? Via a shared
   encrypted file on SharePoint?

3. **Storage on operator machines**: is the key stored in `.Renviron`?
   In the OS keychain? In a `.env` file excluded from version control?
   The pipeline loads it from `Sys.getenv("XNE_PEPPER_KEY")`, which
   means any of these approaches works — but none is enforced.

4. **Rotation policy**: given that rotation requires full re-ingestion,
   is there a rotation schedule? Is it rotation-on-compromise only?

5. **Operator offboarding**: if an operator who knows the key leaves,
   does the key need to be rotated? What is the re-ingestion cost at
   that point?

6. **Audit**: is there a record of who has had access to the key?

## Dependency

ADR-003 (HMAC pseudonymization) depends on this remaining undecided;
the security of the entire PHI handling model rests on this key's
lifecycle being well-governed.

## Recommendation (tentative)

At minimum, document that `XNE_PEPPER_KEY` must:
- Be a random string of at least 32 characters
- Never be stored in any file that is version-controlled or synced
  without encryption
- Be communicated between operators via an encrypted channel only

A shared institutional password manager entry is a reasonable
starting point for a small team.
