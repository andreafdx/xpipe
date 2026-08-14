# Silver Data Quality Framework

## Purpose

Silver harmonization produces analytically usable datasets, but successful harmonization does not guarantee that the resulting data is free from quality concerns.

The goal of the Silver Data Quality Framework is to:

- Detect suspicious records without preventing processing.
- Assess the overall health of a harmonized stream.
- Provide actionable feedback before analysis begins.
- Support future integration with xplorer.
- Preserve harmonized data without modification or record removal.

Quality assessment is **not validation**.

Validation determines whether data can be processed.

Quality assessment determines whether processed data looks trustworthy.

---

# Conceptual Model

```text
Source Data
    ↓
Validation
    ↓
Silver Harmonization
    ↓
Record Quality Findings
    ↓
Stream Quality Assessment
```

Each layer has a distinct responsibility.

---

# Validation

Validation answers:

> Can xpipe process this dataset?

Examples:

- Missing required columns
- Invalid contract configuration
- Invalid registry structure
- Invalid data types
- Broken relationships

Validation failures stop processing.

Validation is not part of the quality framework.

---

# Record Quality Findings

Record quality findings identify suspicious records after harmonization.

They do not prevent loading.

Examples:

- Admission date after discharge date
- Negative length of stay
- Facility not found
- Internal unit code not matched
- External unit code not matched
- Age exceeds expected limits

A single record may produce multiple findings.

---

## Quality Findings Table

One findings table exists for the entire harmonized database.

```text
harmonized.quality
```

### Suggested Structure

```text
table_name
record_id
batch_id
severity
quality_code
message
detected_at
```

### Fields

#### table_name

Source harmonized table.

Examples:

```text
ricovero
anagrafica
ps
procedure
```

#### record_id

Silver record identifier generated from the harmonization method.

This is the authoritative record reference.

Quality findings are linked to records through the Silver identity model, not through batch identifiers.

#### batch_id

Import batch that generated the finding.

Useful for audit and traceability.

Not used as the primary record identifier.

#### severity

```text
ERROR
WARNING
INFO
```

#### quality_code

Stable quality rule identifier.

Examples:

```text
NEGATIVE_LOS
ADMISSION_AFTER_DISCHARGE
UNMATCHED_INTERNAL_UNIT
```

#### message

Human-readable description.

#### detected_at

Timestamp of assessment execution.

---

## Severity Definitions

### ERROR

Record is likely incorrect.

Examples:

- Admission after discharge
- Negative length of stay
- Impossible date sequence

### WARNING

Record is usable but suspicious.

Examples:

- Internal unit not matched
- Facility not matched
- Extremely long stay

### INFO

Record is valid but noteworthy.

Examples:

- Optional information missing
- Rare but plausible values

---

# Stream Quality Assessment

Record findings evaluate individual records.

Stream assessments evaluate the dataset as a whole.

The assessment layer answers:

> Does the harmonized stream look healthy?

Examples:

### Organizational Coverage

```text
Organization match rate = 99.3%
```

Expected.

---

```text
Organization match rate = 72.5%
```

Suspicious.

Possible registry, mapping, or extraction problem.

### Internal Unit Code Presence

Expected:

```text
Internal codes present
```

Observed:

```text
No internal codes detected
```

Possible extraction error.

No individual record is necessarily wrong.

The stream itself appears abnormal.

### Facility Coverage

```text
Facility match rate = 98%
```

Good.

---

```text
Facility match rate = 55%
```

Requires investigation.

### Completeness Indicators

Examples:

```text
Birth date completeness
Resident ASL completeness
Diagnosis completeness
```

---

# Assessment Table

One assessment table exists for the entire harmonized database.

```text
harmonized.assessment
```

### Suggested Structure

```text
scope
indicator_code
category
display_label
display_type
value_num
value_text
severity
message
batch_id
assessed_at
```

---

## Scope

Assessment target.

Examples:

```text
stream
ricovero
anagrafica
ps
```

This allows a single table to contain:

- Stream-wide indicators
- Table-specific indicators

---

## Indicator Code

Stable identifier.

Examples:

```text
ORG_MATCH_RATE
FACILITY_MATCH_RATE
INTERNAL_CODES_PRESENT
MISSING_BIRTHDATE_RATE
```

---

## Category

Logical grouping.

Examples:

```text
ORGANIZATION
COMPLETENESS
CONSISTENCY
TIMELINESS
DEMOGRAPHICS
CLINICAL
```

---

## Display Label

Human-readable name.

Examples:

```text
Organization Match Rate
Internal Unit Codes Present
Missing Birth Date Rate
```

---

## Display Type

Defines the semantic type of the indicator.

Examples:

```text
percentage
count
boolean
rate
text
```

This allows xplorer to render indicators generically without stream-specific code.

---

## Value Fields

### value_num

Numeric value.

Examples:

```text
98.4
1250
0
1
```

### value_text

Optional textual representation.

Examples:

```text
YES
NO
LOW
HIGH
```

---

## Severity

Assessment outcome.

```text
ERROR
WARNING
INFO
```

Examples:

```text
INFO
Organization match rate = 98.4%
```

```text
WARNING
No internal unit codes detected
```

---

## Message

Human-readable explanation.

Examples:

```text
98.4% of records matched an organization
```

```text
No internal unit codes detected in stream
```

---

# Why a Single Quality Table?

Instead of creating:

```text
ricovero_quality
anagrafica_quality
ps_quality
...
```

all findings are consolidated into:

```text
harmonized.quality
```

Advantages:

- Simpler architecture
- Easier querying
- Easier aggregation
- Easier xplorer integration
- Consistent reporting across all streams

Example:

```sql
SELECT
  severity,
  COUNT(*)
FROM harmonized.quality
GROUP BY severity;
```

---

# Why a Single Assessment Table?

Instead of creating:

```text
ricovero_assessment
anagrafica_assessment
ps_assessment
...
```

all indicators are consolidated into:

```text
harmonized.assessment
```

Advantages:

- Stream-wide and table-specific indicators can coexist.
- No proliferation of assessment tables.
- Generic rendering becomes possible.
- Simpler maintenance.

---

# Relationship with Silver Identity

Quality findings are linked to records through the Silver identity model.

Every stream already defines authoritative identity keys in its contract.

Examples:

### SDO

```json
"identity_keys": [
  "codiceIstitutoDiCura",
  "progressivoSDO"
]
```

### EMUR

```json
"identity_keys": [
  "Struttura_CodStrutturaErog",
  "Struttura_Progressivo"
]
```

Quality findings reference the resulting Silver record identifier generated by the harmonization method.

The quality subsystem does not need to know the underlying source identity keys.

---

# Relationship with Batch IDs

Batch identifiers are provenance metadata.

They indicate:

- Which import produced the finding
- When the finding was generated
- Which batch was assessed

Batch identifiers are useful for audit and traceability.

They are **not** the primary identifier of a record.

Record identity remains governed by the Silver identity model.

---

# xplorer Integration

xplorer should consume quality information, not compute it.

Example summary:

```text
Quality Findings

ERROR   : 150
WARNING : 2,400
INFO    : 450
```

Example assessment output:

```text
Organization

✓ Organization Match Rate ...... 98.4%
✓ Facility Match Rate .......... 99.1%
⚠ Internal Codes Present ....... NO

Completeness

✓ Birth Date Completeness ...... 99.8%
✓ Resident ASL Completeness .... 100.0%
```

Because assessments include semantic display metadata (`display_label` and `display_type`), xplorer can render indicators generically without stream-specific presentation code.

---

# Design Principles

- Quality assessment does not replace validation.
- Harmonized data is never modified by quality checks.
- Records are never discarded because of quality findings.
- Findings operate at the record level.
- Assessments operate at the stream level.
- Quality artifacts belong to the harmonized schema.
- The framework must be extensible.
- xpipe generates quality information.
- xplorer consumes and displays quality information.
- The Silver identity model remains the authoritative record reference mechanism.

---

# Target Schema Layout

```text
current
├─ ricovero
├─ anagrafica
├─ ...
│
harmonized
├─ ricovero
├─ anagrafica
├─ ...
├─ quality
└─ assessment
```

The Silver Data Quality Framework consists of:

- One harmonized quality findings table (`harmonized.quality`)
- One harmonized assessment table (`harmonized.assessment`)

This provides a consistent, stream-oriented quality subsystem while allowing stream-specific quality rules and indicators to evolve independently over time.