---
date: 2026-08-12
---

# Organizational Registry Invariants

This document defines the non-negotiable invariants of the
Organizational Registry subsystem.

These invariants describe what must always be true for organizational
master data to be considered valid.

They are independent of implementation details, storage formats,
validation implementations, or enrichment strategies.

If any invariant is violated, the Organizational Registry is considered
invalid even if the registry can still be loaded successfully.

------------------------------------------------------------------------

# Global Organizational Invariants

## O1. Organizational semantics are registry-driven

Organizational meaning must be derived exclusively from the
Organizational Registry.

Code must not hardcode:

- organizations
- structures
- facilities
- departments
- units
- unit codes

outside the registry definitions.

Organizational meaning belongs to master data, not application logic.

------------------------------------------------------------------------

## O2. Registry contents are authoritative

The Organizational Registry is the authoritative source of
organizational metadata within a project.

Analytical enrichments, mappings, and organizational classifications
must derive their meaning from the registry.

Downstream layers may cache or materialize registry information, but
must not redefine organizational semantics.

------------------------------------------------------------------------

## O3. Organizational registries are version-controlled assets

Organizational registries must exist as project-managed artifacts.

Organizational meaning must never depend on:

- runtime objects
- temporary lookup tables
- manual code edits
- external systems not recorded in the project

A complete Organizational Registry must be reproducible from project
artifacts alone.

------------------------------------------------------------------------

# Hierarchy Invariants

## O4. The Organizational Registry contains two independent hierarchies

The registry model consists of two independent hierarchies.

### Organizational hierarchy

``` text
Organization
└── Department
    └── Unit
```

### Facility hierarchy

``` text
Organization
└── Structure
    └── Facility
```

### Bridge

``` text
Unit Code
```

Unit codes connect the two hierarchies.

The hierarchies must not be collapsed into a single tree.

------------------------------------------------------------------------

## O5. Unit Code is the bridge entity

Every Unit Code references:

- exactly one Unit;
- exactly one Facility.

Unit Codes are the sole organizational entities that simultaneously
belong to both hierarchies.

------------------------------------------------------------------------

## O6. Units and Facilities are many-to-one relationships to Unit Codes

A Unit may be associated with multiple Unit Codes.

A Facility may be associated with multiple Unit Codes.

This is a valid and expected configuration.

Example:

``` text
UOC Cardiologia
├── 150901002601
├── 150901005001
└── 150901008001
```

All three operational Unit Codes may belong to the same Unit.

------------------------------------------------------------------------

## O7. Departments and Units are not constrained by Facility boundaries

Departments may span multiple Facilities.

Departments may span multiple Structures.

Units may be represented by multiple Unit Codes operating in different
Facilities.

The registry must not assume:

``` text
Department → Facility
```

or

``` text
Unit → Facility
```

ownership relationships.

------------------------------------------------------------------------

# Referential Integrity Invariants

## O8. Parent entities must exist

Every declared parent relationship must resolve successfully.

Required relationships:

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

Missing parent references are forbidden.

------------------------------------------------------------------------

## O9. A valid registry contains no orphan entities

A valid registry contains no entity whose parent cannot be resolved.

All entities must belong to a valid hierarchy path terminating at an
Organization.

------------------------------------------------------------------------

# Temporal Invariants

## O10. Validity windows are mandatory

Every registry entity must declare:

``` text
valid_from
valid_to
```

`valid_from` is required.

`valid_to` is optional.

------------------------------------------------------------------------

## O11. Validity windows must be ordered

For any record:

``` text
valid_to >= valid_from
```

whenever `valid_to` is not NULL.

Negative validity periods are forbidden.

------------------------------------------------------------------------

## O12. Child validity must be contained within parent validity

A child entity must never exist outside the validity range of its
parent.

Required containment relationships:

``` text
Structure → Organization
Facility → Structure
Department → Organization
Unit → Department
Unit Code → Unit
Unit Code → Facility
```

Containment is mandatory.

------------------------------------------------------------------------

## O13. Overlapping validity periods are forbidden

Overlapping validity periods are forbidden for the same logical entity.

Validation applies to:

``` text
organization_uid
structure_code
facility_code
department_uid
uo_uid
facility_code + unit_code
```

A given entity must have at most one active validity period at any point
in time.

------------------------------------------------------------------------

# Unit Code Invariants

## O14. Unit Codes are immutable identifiers

The meaning of a Unit Code is defined by the registry.

Unit Code semantics must not be inferred from:

- naming patterns;
- application logic;
- reporting assumptions.

The registry is the sole authority.

------------------------------------------------------------------------

## O15. Internal Unit Codes require an external parent

For:

``` text
is_external = FALSE
```

the following must hold:

``` text
parent_unit_code != NULL
```

and

``` text
parent_unit_code
  → existing external Unit Code
```

Internal Unit Codes without a valid external parent are invalid.

------------------------------------------------------------------------

## O16. External Unit Codes must be resolvable

Every external Unit Code represents a reporting entity that may be
referenced by internal Unit Codes.

A parent Unit Code referenced by an internal Unit Code must exist.

------------------------------------------------------------------------

# Enrichment Invariants

## O17. Organizational enrichment is deterministic

Given:

- identical source data;
- identical Organizational Registry;

organizational enrichment must always produce identical results.

No probabilistic matching is permitted.

No heuristic matching is permitted.

------------------------------------------------------------------------

## O18. Facility-aware matching takes precedence

When source data contains:

``` text
facility_code + unit_code
```

organizational enrichment must resolve matches using both components.

Example:

``` text
150901002601
150902002601
```

must be treated as distinct organizational identifiers.

Matching only on:

``` text
unit_code
```

is permitted only when facility information is unavailable.

------------------------------------------------------------------------

## O19. Original source identifiers are preserved

Organizational enrichment supplements source data.

It must not replace or overwrite source organizational identifiers.

Original source organizational codes must remain available after
enrichment.

------------------------------------------------------------------------

## O20. Registry failure must not corrupt source data

If the registry is invalid or unavailable:

- enrichment may be skipped;
- enrichment columns may be populated with NULL values;
- warnings may be emitted;

but source data must remain unchanged.

Registry failures must never silently alter source values.

------------------------------------------------------------------------

# Validation Invariants

## O21. Validation is authoritative

A registry that fails validation is organizationally invalid.

Consumers may choose whether invalid registries should:

- abort processing; or
- disable enrichment;

but validation outcomes themselves must not be ignored.

------------------------------------------------------------------------

## O22. Organizational validation must be reproducible

Validation results must depend only on:

- registry contents;
- validation rules;

and not on:

- execution order;
- runtime state;
- external services;
- manual intervention.

------------------------------------------------------------------------

## O23. Temporal resolution must be deterministic

When multiple historical versions of the same registry entity exist,
the version selected for enrichment must be determined exclusively by
the supplied reference date and registry validity windows.

Current organizational metadata must never be substituted for a
historically valid registry version.

------------------------------------------------------------------------

# Change Policy

Any change that violates an Organizational Registry invariant requires:

- explicit discussion;
- an update to this document;
- a clear justification.

Code changes which silently violate these invariants are considered
regressions.
