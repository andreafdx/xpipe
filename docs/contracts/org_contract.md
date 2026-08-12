---
date: 2026-08-12
---

# Organizational Registry — Contract Specification

## Purpose

The Organizational Registry defines the organizational master data used
by xpipe for enrichment, reporting, governance, and analytical
consistency.

Organizational registries are:

- shared project resources;
- maintained outside of the medallion architecture;
- independent from Bronze, Silver, and Gold layers;
- version-controlled and validated;
- intended to provide stable organizational semantics across
  heterogeneous healthcare data sources.

The Organizational Registry is not a source dataset.

It is a curated reference layer describing the organizational structure
of healthcare providers and operational units.

------------------------------------------------------------------------

## Scope

The Organizational Registry supports:

- organizational enrichment of Silver-harmonized datasets;
- reporting by department, unit, structure, or organization;
- mapping of operational reporting codes to analytical organizational
  entities;
- organizational change tracking through temporal validity windows;
- reproducible organizational semantics.

The registry does not store operational activity data.

------------------------------------------------------------------------

## Registry Hierarchy

The Organizational Registry is composed of two independent hierarchies:

Organizational hierarchy

``` text
Organization
└── Department
    └── Unit
```

``` text
Facility hierarchy

Organization
└── Structure
    └── Facility
```

``` text
Full picture

          Organization
          /          \
         /            \
  Department        Structure
       |                |
       |                |
      Unit          Facility
         \            /
          \          /
           \        /
            Unit Code
```

Unit codes bridge the two hierarchies.

Each unit code references:

- exactly one Unit;
- exactly one Facility.

A Unit may be associated with multiple unit codes.

A Facility may host multiple unit codes.

This allows a single organizational unit to operate across multiple
facilities, and allows multiple operational reporting codes to map to
the same Unit.

All parent-child relationships are mandatory and validated.

These hierarchies are intentionally independent.

A department may span multiple facilities and structures. A unit may be
represented by multiple operational unit codes located in different
facilities.

The unit_code registry acts as the bridge between the organizational and
facility dimensions.

------------------------------------------------------------------------

## Registry Files

The registry is stored under:

``` text
data/shared/org/
```

The registry consists of six CSV files:

``` text
organizations.csv
structures.csv
facilities.csv
departments.csv
units.csv
unit_codes.csv
```

All files are required for a valid organizational registry.

------------------------------------------------------------------------

# organizations.csv

## Purpose

Represents healthcare organizations.

Examples:

``` text
AORN Antonio Cardarelli
AORN Santobono-Pausilipon
ASL Napoli 1 Centro
```

## Columns

``` text
organization_uid
organization_name
valid_from
valid_to
```

## Key

``` text
organization_uid
```

## Example

``` csv
organization_uid,organization_name,valid_from,valid_to
cardarelli,AORN Antonio Cardarelli,2022-01-01,
```

------------------------------------------------------------------------

# structures.csv

## Purpose

Represents institutional healthcare structures.

Structures generally correspond to NSIS-recognized healthcare providers.

## Columns

``` text
structure_code
structure_name
region_code
asl_code
organization_uid
valid_from
valid_to
```

## Parent

``` text
organization_uid
→ organizations.organization_uid
```

## Key

``` text
structure_code
```

## Example

``` csv
structure_code,structure_name,region_code,asl_code,organization_uid,valid_from,valid_to
150901,Ospedale Cardarelli,150,204,cardarelli,2022-01-01,
```

------------------------------------------------------------------------

# facilities.csv

## Purpose

Represents operational facilities.

A facility is the organizational entity against which operational unit
codes are recorded.

## Columns

``` text
facility_code
facility_name
structure_code
valid_from
valid_to
```

## Parent

``` text
structure_code
→ structures.structure_code
```

## Key

``` text
facility_code
```

## Example

``` csv
facility_code,facility_name,structure_code,valid_from,valid_to
15090100,Ospedale Cardarelli,150901,2022-01-01,
```

------------------------------------------------------------------------

# departments.csv

## Purpose

Represents organizational departments.

Departments group multiple units.

## Columns

``` text
department_uid
department_name
organization_uid
valid_from
valid_to
```

## Parent

``` text
organization_uid
→ organizations.organization_uid
```

## Key

``` text
department_uid
```

## Example

``` csv
department_uid,department_name,organization_uid,valid_from,valid_to
1,Dipartimento dell'emergenza e dell'area critica,cardarelli,2022-01-01,
```

------------------------------------------------------------------------

# units.csv

## Purpose

Represents clinical and organizational units.

Units are stable analytical entities used for reporting and enrichment.

## Columns

``` text
uo_uid
uo_name
uo_type
department_uid
valid_from
valid_to
```

## Parent

``` text
department_uid
→ departments.department_uid
```

## Key

``` text
uo_uid
```

## Allowed Unit Types

``` text
UOC
UOSD
```

## Example

``` csv
uo_uid,uo_name,uo_type,department_uid,valid_from,valid_to
1,Cardiologia con UTIC,UOC,2,2022-01-01,
```

------------------------------------------------------------------------

# unit_codes.csv

## Purpose

Represents operational reporting codes associated with organizational
units.

A unit may be associated with multiple reporting codes.

Unit codes are the registry used for Silver organizational enrichment.

## Columns

``` text
facility_code
unit_code
short_name
uo_uid
parent_unit_code
is_external
in_week
valid_from
valid_to
```

## Parent Relationships

``` text
facility_code
→ facilities.facility_code

uo_uid
→ units.uo_uid
```

## Analytical Key

``` text
facility_code
unit_code
```

## Example

``` csv
facility_code,unit_code,short_name,uo_uid,parent_unit_code,is_external,in_week,valid_from,valid_to
15090100,2601,Medicina 1,20,,TRUE,,2022-01-01,
```

------------------------------------------------------------------------

# Unit Code Model

Two categories of unit codes exist.

## External Unit Codes

External unit codes represent reporting entities directly exposed in
operational systems (NSIS).

Example:

``` text
2601
```

Characteristics:

``` text
is_external = TRUE
parent_unit_code = NULL
```

------------------------------------------------------------------------

## Internal Unit Codes

Internal unit codes are linked to an external reporting code.

Example:

``` text
2691
```

Characteristics:

``` text
is_external = FALSE
parent_unit_code = 2601
```

Internal unit codes must always reference an existing external parent
code.

------------------------------------------------------------------------

# Temporal Model

Every registry contains:

``` text
valid_from
valid_to
```

## Rules

### valid_from

Required.

``` text
valid_from != NULL
```

### valid_to

Optional.

``` text
valid_to = NULL
```

means:

``` text
open-ended validity
```

### Date Ordering

The following condition must always hold:

``` text
valid_to >= valid_from
```

when valid_to is not NULL.

------------------------------------------------------------------------

# Temporal Containment

Child entities must be fully contained within parent validity windows.

## Required Relationships

``` text
structure -> organization
facility -> structure
department -> organization
unit -> department
unit_code -> unit
unit_code -> facility
```

Example:

``` text
Organization
2022-01-01 → 2025-12-31

Department
2023-01-01 → 2024-12-31

VALID
```

Example:

``` text
Organization
2022-01-01 → 2022-12-31

Department
2023-01-01 → 2024-12-31

INVALID
```

------------------------------------------------------------------------

# Overlapping Periods

Overlapping validity periods are forbidden for the same logical entity.

Validated entities:

``` text
organization_uid
structure_code
facility_code
department_uid
uo_uid
facility_code + unit_code
```

Example:

``` text
2601
2022-01-01 → 2023-12-31

2601
2023-06-01 → NULL
```

INVALID.

------------------------------------------------------------------------

# Referential Integrity Rules

A valid organizational registry guarantees:

``` text
structures.organization_uid
  → organizations.organization_uid

facilities.structure_code
  → structures.structure_code

departments.organization_uid
  → organizations.organization_uid

units.department_uid
  → departments.department_uid

unit_codes.uo_uid
  → units.uo_uid

unit_codes.facility_code
  → facilities.facility_code
```

Missing references are not permitted.

------------------------------------------------------------------------

# Organizational Enrichment

Silver-harmonized profiles may enrich records using the organizational
registry.

Organizational enrichment is deterministic.

The source identifier is preserved.

The enrichment supplements source data and does not replace source
identifiers.

------------------------------------------------------------------------

## Unit-Code Resolution

When available, enrichment resolves mappings using:

``` text
facility_code
+
unit_code
```

rather than unit_code alone.

This avoids ambiguity when multiple facilities reuse the same unit_code
values.

Example:

``` text
150901002601
150902002601
```

may both contain:

``` text
unit_code = 2601
```

but correspond to different facilities.

The registry resolves the correct mapping by matching:

``` text
facility_code
+
unit_code
```

together.

------------------------------------------------------------------------

## Enrichment Outputs

Current Silver organizational enrichment may produce:

``` text
<column>_unit_code_internal
<column>_unit_code_external
<column>_unit_short_name_external
```

Example:

``` text
Source:
150901002601

Output:
internal_code = 2601
external_code = 2601
short_name    = Medicina 1
```

The original source code is preserved.

------------------------------------------------------------------------

## Temporal Resolution of Organizational Metadata

Organizational metadata is resolved as of a reference date supplied by
the consuming process.

When multiple registry versions exist for the same organizational
identifier, the version whose validity window contains the reference
date is selected.

Example:

``` text
facility_code,unit_code,short_name,valid_from,valid_to
15090100,2601,Cardiologia 1,2020-01-01,2022-12-31
15090100,2601,Cardiologia con UTIC,2023-01-01,
``` 

``` text
Reference date: 2022-01-01
→ Cardiologia 1
``` 

``` text
Reference date: 2024-01-01
→ Cardiologia con UTIC
``` 

------------------------------------------------------------------------

# Validation Guarantees

A successfully validated organizational registry guarantees:

- all registry files are present;
- all required columns are present;
- all foreign keys resolve;
- all validity windows are valid;
- all temporal containment rules are satisfied;
- no overlapping validity periods exist;
- unit-code parent mappings are valid;
- organizational enrichment is deterministic and reproducible.

------------------------------------------------------------------------

# Relationship to Silver

The Organizational Registry is not part of Silver.

Silver-harmonized profiles may use the Organizational Registry as an
optional enrichment source.

The Organizational Registry is a shared master-data layer and exists
outside the medallion architecture.

Neither Silver-current nor Silver-harmonized own organizational data.

Silver-harmonized profiles may consume organizational registries to:

- resolve organizational unit metadata;
- map operational reporting codes to analytical entities;
- support reporting by unit, department, facility, structure, or
  organization;
- provide stable organizational semantics across source systems.

Organizational enrichment is deterministic and reproducible.

The same source code and registry state must always produce the same
enrichment result.

If the Organizational Registry is unavailable or invalid:

- Silver promotion may continue;
- organizational enrichment may be skipped;
- enrichment output columns may be populated with NULL values;
- a warning must be emitted to the user.

Organizational Registry failures must not silently alter enrichment
logic.

Organizational enrichment supplements source data and does not replace
or modify original source identifiers.

The original source organizational codes must always remain available in
the harmonized dataset.
