# Future Idea: Silver Quality Assessment Framework

## Motivation

Silver harmonized datasets may contain records that are technically
valid and loadable, but still present quality concerns that could affect
analysis.

Examples:

- Admission date after discharge date
- Negative length of stay
- Unmatched unit code
- Unmatched facility code
- Age outside expected bounds
- Inconsistent clinical or organizational information

The goal is to make potential data quality issues visible, measurable,
and filterable without preventing data loading.

------------------------------------------------------------------------

## High-Level Concept

Introduce a quality assessment step after Silver Harmonization.

``` text
Bronze
    ↓
Silver Harmonized
    ↓
Silver Quality Assessment
```

Quality checks should be modular and extensible so that new rules can be
added over time without redesigning the framework.

------------------------------------------------------------------------

## Quality Findings Table

Create a dedicated quality findings table for each stream.

Example:

``` text
silver_sdo_quality
```

Suggested columns:

``` text
record_id (unique, based on jsons rules)
batch_id
quality_code
severity
message
detected_at
```

Possible future additions:

``` text
stream_id
rule_id
```

Example rows:

``` text
12345 | B20260812 | Q001 | ERROR   | Admission date after discharge date
12345 | B20260812 | Q010 | WARNING | Unit code not found in registry
67890 | B20260812 | Q020 | INFO    | Missing discharge unit
```

A record may have multiple findings.

------------------------------------------------------------------------

## Quality Flags on Harmonized Tables

Store lightweight summary flags directly on harmonized tables to support
fast filtering.

Suggested columns:

``` text
has_quality_findings
has_error
has_warning
has_info
```

Examples:

``` text
FALSE FALSE FALSE FALSE
TRUE  FALSE TRUE  FALSE
TRUE  TRUE  TRUE  FALSE
```

The detailed findings remain in the quality table.

------------------------------------------------------------------------

## Severity Levels

### INFO

Data is valid and generally usable.

Examples:

- Rare but plausible values
- Missing optional information

### WARNING

Data is usable but suspicious.

Examples:

- Unit code not found in registry
- Extremely long length of stay
- Unusual value combinations

### ERROR

Data is likely incorrect.

Examples:

- Admission after discharge
- Negative length of stay
- Impossible date relationships

------------------------------------------------------------------------

## Quality Registry

Maintain a registry of quality codes.

Example:

``` text
quality_code | severity | description
```

``` text
Q001 | ERROR   | Admission date after discharge
Q002 | ERROR   | Negative length of stay
Q010 | WARNING | Unit code not found in registry
Q020 | INFO    | Missing discharge unit
```

Quality codes are the authoritative identifier.

Messages exist primarily for user readability.

------------------------------------------------------------------------

## Design Principles

- Quality findings do not replace validation.
- Validation determines whether data can be processed.
- Quality findings identify suspicious but processable records.
- Multiple findings may exist for the same record.
- Rules should be modular and independently maintainable.
- New quality checks should be easy to add over time.
- Findings should remain linked to the originating record and batch.

------------------------------------------------------------------------

## Possible Future xplorer Integration

Potential filtering options:

``` r
quality = "all"
quality = "clean"
quality = "warning"
quality = "error"
quality = "issues"
```

Possible user warning on load:

``` text
3,000 records contain quality findings:

150 ERROR
2,400 WARNING
450 INFO

Use quality filters to inspect affected records.
```

Final behaviour and defaults to be decided later.

------------------------------------------------------------------------

## Initial Candidate Rules

### ERROR

- Admission date after discharge date
- Negative length of stay
- Impossible date sequences
- no ricovero (or riabilitazione, this has to be done first) table for
  anagrafica

### WARNING

- Internal unit not matched
- External unit not matched
- Facility not matched
- Extremely long length of stay
- Age exceeds expected threshold

### INFO

- Missing optional fields
- Rare but plausible values

------------------------------------------------------------------------

## Guiding Principle

The framework should support data quality monitoring, auditing, and
investigation without altering the original harmonized data or silently
discarding records.
