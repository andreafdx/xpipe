# Implementation Plan: Silver Data Quality Framework

## Objective

Introduce a generic, extensible Quality Assessment Framework for Silver harmonization.

The framework will produce two quality artifacts for each Silver stream:

```text
harmonized.q_findings
harmonized.q_assessment
```

The framework must:

- Remain stream-specific in quality logic.
- Remain generic in execution and persistence.
- Reuse the existing Silver profile architecture.
- Support future xplorer integration.
- Avoid proliferation of per-table quality tables.
- Avoid stream-specific rendering logic in xplorer.
- Keep validation and quality assessment clearly separated.

---

# Conceptual Model

```text
Source Data
    ↓
Validation
    ↓
Silver Current
    ↓
Silver Harmonization
    ↓
Quality Assessment
```

Resulting Silver outputs:

```text
current.*
harmonized.*
harmonized.q_findings
harmonized.q_assessment
```

---

# Validation vs Quality Assessment

Validation answers:

> Can xpipe process the data?

Examples:

- Missing required columns
- Invalid contract configuration
- Invalid registry structure
- Invalid data types
- Broken relationships

Validation failures stop processing.

---

Quality assessment answers:

> Does the harmonized data look trustworthy?

Examples:

- Admission date after discharge
- Negative length of stay
- Internal unit not matched
- No internal codes detected in entire stream
- Low organization match rate

Quality findings never prevent harmonization.

Quality assessment is informational.

---

# Schema Layout

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
├─ q_findings
└─ q_assessment
```

Quality artifacts are considered part of the harmonized layer.

No additional schema is required.

---

# Record-Level Quality Findings

## Purpose

Record-level findings identify suspicious individual records.

Multiple findings may be associated with the same record.

Examples:

```text
Negative length of stay
Admission after discharge
Internal unit code not matched
Facility not matched
```

---

# Table: harmonized.q_findings

## Suggested Structure

```text
table_name
record_id
batch_id
severity
quality_code
message
detected_at
```

## Fields

### table_name

Source harmonized table.

Examples:

```text
ricovero
anagrafica
ps
obi
```

---

### record_id

Silver record identifier.

This is the primary entity reference.

Quality findings are linked using the Silver identity model.

---

### batch_id

Batch that produced the finding.

Used for:

- audit
- traceability
- provenance

Not used as primary identity.

---

### severity

```text
ERROR
WARNING
INFO
```

---

### quality_code

Stable identifier.

Examples:

```text
NEGATIVE_LOS
ADMISSION_AFTER_DISCHARGE
UNMATCHED_INTERNAL_UNIT
UNMATCHED_FACILITY
```

---

### message

Human-readable explanation.

Example:

```text
Internal unit code not matched to registry
```

---

### detected_at

Timestamp of assessment execution.

---

# Severity Categories

## ERROR

Record is likely incorrect.

Examples:

```text
Admission after discharge
Negative length of stay
Impossible date sequence
```

---

## WARNING

Record is usable but suspicious.

Examples:

```text
Internal unit not matched
Facility not matched
Extreme length of stay
```

---

## INFO

Record is valid but noteworthy.

Examples:

```text
Missing optional field
Rare but plausible value
```

---

# Stream-Level Quality Assessment

## Purpose

Assessments evaluate the health of the dataset as a whole.

Assessments are not tied to individual records.

They answer:

> Does this stream look healthy?

---

## Examples

### Organizational Coverage

```text
Organization match rate = 99.4%
```

Expected.

---

```text
Organization match rate = 72.1%
```

Suspicious.

---

### Internal Codes Present

Expected:

```text
Internal codes present
```

Observed:

```text
No internal codes present
```

Possible extraction issue.

No individual record is necessarily invalid.

The stream itself appears unusual.

---

### Facility Coverage

```text
Facility match rate = 98%
```

Good.

---

```text
Facility match rate = 50%
```

Requires investigation.

---

### Completeness Indicators

Examples:

```text
Birth date completeness
Diagnosis completeness
Resident ASL completeness
```

---

# Table: harmonized.q_assessment

## Suggested Structure

```text
scope
indicator_code
indicator_label
indicator_type
category
value_num
value_text
severity
message
batch_id
assessed_at
```

---

## scope

Scope of the assessment.

Examples:

```text
stream
ricovero
anagrafica
ps
```

This allows both:

- stream-wide indicators
- table-specific indicators

inside a single table.

---

## indicator_code

Stable identifier.

Examples:

```text
ORG_MATCH_RATE
FACILITY_MATCH_RATE
INTERNAL_CODES_PRESENT
MISSING_BIRTHDATE_RATE
```

---

## indicator_label

Human-readable label.

Examples:

```text
Organization Match Rate
Facility Match Rate
Internal Codes Present
Missing Birth Date Rate
```

---

## indicator_type

Semantic type of the metric.

Examples:

```text
percentage
count
boolean
rate
text
```

This allows generic rendering by xplorer.

---

## category

Logical grouping.

Examples:

```text
ORGANIZATION
COMPLETENESS
CONSISTENCY
DEMOGRAPHICS
CLINICAL
TIMELINESS
```

---

## value_num

Numeric value.

Examples:

```text
98.4
2450
0
1
```

---

## value_text

Optional textual value.

Examples:

```text
YES
NO
HIGH
LOW
```

---

## severity

Assessment outcome.

```text
INFO
WARNING
ERROR
```

---

## message

Human-readable explanation.

Example:

```text
98.4% of records successfully matched an organization
```

---

## batch_id

Batch associated with the assessment.

Included for auditability.

---

## assessed_at

Assessment execution timestamp.

---

# Quality Profile Architecture

Quality logic should remain stream-specific.

Execution should remain generic.

This mirrors the existing harmonization architecture.

---

# Harmonization Architecture

Current:

```text
Silver Engine
    ↓
Harmonization Profile
```

Example:

```r
.silver_profile_sdo_harmonized_v1()

.silver_profile_emur_harmonized_v1()
```

---

# Quality Architecture

Proposed:

```text
Silver Engine
    ↓
Quality Profile
```

Example:

```r
.silver_quality_sdo_v1()

.silver_quality_emur_v1()
```

---

# Quality Profile Registry

```r
.silver_quality_profile_registry <- list(
  sdo_quality_v1  = .silver_quality_sdo_v1,
  emur_quality_v1 = .silver_quality_emur_v1
)
```

---

# silver.json Extension

Current:

```json
{
  "sdo": {
    "harmonized": {
      "enabled": true,
      "profile": "sdo_harmonized_v1"
    }
  }
}
```

Proposed:

```json
{
  "sdo": {
    "harmonized": {
      "enabled": true,
      "profile": "sdo_harmonized_v1"
    },

    "quality": {
      "enabled": true,
      "profile": "sdo_quality_v1"
    }
  }
}
```

---

# Quality Orchestrator

Introduce a new internal function:

```r
.run_silver_quality_profile()
```

Responsibilities:

```text
1. Resolve quality profile
2. Execute profile
3. Validate outputs
4. Write harmonized.q_findings
5. Write harmonized.q_assessment
```

The orchestrator remains fully generic.

---

# Quality Profile Contract

Quality profiles should return data.

They should not directly create tables.

---

## Return Structure

```r
list(
  findings = findings_df,
  assessment = assessment_df
)
```

The framework writes:

```text
harmonized.q_findings
harmonized.q_assessment
```

---

# Example Findings Output

```r
tibble::tibble(
  table_name = "ricovero",
  record_id = "...",
  batch_id = "...",
  severity = "WARNING",
  quality_code = "UNMATCHED_INTERNAL_UNIT",
  message = "Internal unit code not matched"
)
```

---

# Example Assessment Output

```r
tibble::tibble(
  scope = "ricovero",
  indicator_code = "ORG_MATCH_RATE",
  indicator_label = "Organization Match Rate",
  indicator_type = "percentage",
  category = "ORGANIZATION",
  value_num = 98.4,
  value_text = NA_character_,
  severity = "INFO",
  message = "98.4% organization match rate"
)
```

---

# Quality Helper Structure

Profiles should remain lightweight.

Preferred structure:

```r
.silver_quality_sdo_v1 <- function(...) {

  list(
    findings = .sdo_quality_findings(con),
    assessment = .sdo_quality_assessment(con)
  )

}
```

Supporting helpers:

```r
.sdo_quality_findings()
.sdo_quality_assessment()

.emur_quality_findings()
.emur_quality_assessment()
```

---

# Pipeline Integration

Current:

```text
.promote_all_harmonized_tables()
        ↓
harmonization_profile()
        ↓
write log
```

Proposed:

```text
.promote_all_harmonized_tables()
        ↓
harmonization_profile()
        ↓
quality_profile()
        ↓
write q_findings
        ↓
write q_assessment
        ↓
write log
```

Quality assessment always operates on the final harmonized dataset.

---

# Phase 1: Framework

Objective:

Build infrastructure first.

Keep initial rule set minimal.

## Step 1

Create:

```text
harmonized.q_findings
harmonized.q_assessment
```

schemas.

---

## Step 2

Implement:

```r
.validate_quality_findings()
.validate_quality_assessment()
```

---

## Step 3

Implement:

```r
.run_silver_quality_profile()
```

---

## Step 4

Create:

```r
.silver_quality_profile_registry
```

---

## Step 5

Extend:

```json
silver.json
```

with the quality section.

---

## Step 6

Update:

```r
.promote_to_silver_harmonized()
```

to execute quality assessment after harmonization.

---

# Phase 2: Initial SDO Indicators

Implement a small initial set.

## Assessments

### ORG_MATCH_RATE

Percentage of records successfully matched to an organization.

---

### FACILITY_MATCH_RATE

Percentage of records successfully matched to a facility.

---

### INTERNAL_CODES_PRESENT

Boolean indicator.

Purpose:

Detect streams containing only external unit codes.

Severity:

```text
INFO
```

when present.

```text
WARNING
```

when absent.

---

## Findings

### UNMATCHED_INTERNAL_UNIT

Severity:

```text
WARNING
```

Generated when internal unit matching fails.

---

# Phase 3: xplorer Integration

xplorer should not calculate quality.

xplorer consumes:

```text
harmonized.q_findings
harmonized.q_assessment
```

Example:

```text
Quality Findings

ERROR   : 150
WARNING : 2400
INFO    : 450
```

```text
Organization

✓ Organization Match Rate ... 98.4%
✓ Facility Match Rate ....... 99.2%
⚠ Internal Codes Present .... NO
```

Rendering is driven by:

```text
indicator_label
indicator_type
```

without stream-specific code.

---

# Final Architecture

```text
Silver Harmonization
        ↓
Quality Assessment
        ↓
harmonized.q_findings
harmonized.q_assessment
        ↓
xplorer
```

Responsibilities:

```text
xpipe
    Computes quality
    Stores quality

xplorer
    Reads quality
    Displays quality
```

The framework remains generic, while individual streams remain free to define their own findings and assessment indicators.