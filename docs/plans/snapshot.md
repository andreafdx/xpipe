---
date: 2026-05-22
---


## Silver-current snapshot rebuild

Silver-current may be rebuilt as of an ingestion snapshot.

The optional `as_of` parameter limits eligible Bronze rows to batches with:

```sql
__batch_created_at <= as_of
```
Currentness is then determined among eligible rows only:

```sql
ORDER BY __batch_created_at DESC, __batch_id DESC
LIMIT 1
```

The snapshot parameter is based on ingestion lineage, not clinical dates,
event dates, discharge dates, admission dates, or stream anchor semantics.

If `as_of` is absent, Silver-current uses all eligible Bronze rows and
therefore represents the latest imported state.

### Implementation tasks

- Add optional `as_of = NULL` to `promote_to_silver()`.
- validate or normalize `as_of` to a timestamp format.
- Propagate `as_of` to `.promote_to_silver_current()`.
- Propagate `as_of` to `.is_silver_up_to_date()`.
- In anchor selection, filter Bronze anchor rows by `__batch_created_at <= as_of` when `as_of` is not NULL.
- Secondary tables remain filtered through `identity_keys + __batch_id`.
- Update `.is_silver_up_to_date()` to compare against the latest eligible Bronze batch under the same `as_of`.
- Show `as_of` in dry-run output and promotion messages.
- Update `inspect_silver_current()` later to report whether Silver is current relative to latest Bronze or to an explicit snapshot.


`as_of` must be interpreted as an ingestion timestamp and compared against
Bronze `__batch_created_at`. It does not refer to domain/event time.

