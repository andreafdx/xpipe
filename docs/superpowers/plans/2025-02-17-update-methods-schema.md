# Update JSON Schemas & Methods Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the methods schema and definition to support input types and components.

**Architecture:** 
1. Modify `inst/schema/methods.schema.json` to include `input_type` and `components` properties.
2. Update `data/methods.json` to include new fields and a new method.
3. Validate the changes using a Node.js validation script.

**Tech Stack:** JSON Schema, Node.js, Ajv (via npx)

---

### Task 1: Create Validation Test Script

**Files:**
- Create: `tests/validate_methods.js`

- [ ] **Step 1: Write the validation script**

```javascript
const Ajv = require('ajv');
const fs = require('fs');
const path = require('path');

const schemaPath = path.resolve(__dirname, '../inst/schema/methods.schema.json');
const dataPath = path.resolve(__dirname, '../data/methods.json');

const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
const data = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

const ajv = new Ajv();
const validate = ajv.compile(schema);
const valid = validate(data);

if (!valid) {
  console.error('Validation failed:');
  console.error(ajv.errorsText(validate.errors));
  process.exit(1);
} else {
  console.log('Validation passed!');
}
```

- [ ] **Step 2: Run the validation script (Verify RED)**

Run: `node tests/validate_methods.js`
Expected: FAIL (once we start adding properties to schema and data doesn't match yet, or vice versa)
Actually, right now it should PASS if the current files are valid.
I'll add the new requirements to the schema first, then see it FAIL.

### Task 2: Update `inst/schema/methods.schema.json`

**Files:**
- Modify: `inst/schema/methods.schema.json`

- [ ] **Step 1: Add new properties and update required list**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "additionalProperties": {
    "type": "object",
    "required": ["stream", "type", "input_type"],
    "properties": {
      "stream": { "type": "string" },
      "type": { "type": "string", "enum": ["access_db", "xml", "csv"] },
      "input_type": { "type": "string", "enum": ["file", "directory"] },
      "components": { "type": "object", "additionalProperties": { "type": "string" } },
      "table": { "type": "string" },
      "mapping": { "type": "object", "additionalProperties": { "type": "string" } }
    }
  }
}
```

- [ ] **Step 2: Run validation script (Verify RED)**

Run: `node tests/validate_methods.js`
Expected: FAIL (because `sdo_hosp_a` lacks `input_type`)

- [ ] **Step 3: Commit schema changes**

```bash
git add inst/schema/methods.schema.json
git commit -m "schema: update methods schema to include input_type and components"
```

### Task 3: Update `data/methods.json`

**Files:**
- Modify: `data/methods.json`

- [ ] **Step 1: Update `sdo_hosp_a` and add `sdo_campania_xml`**

```json
{
  "sdo_hosp_a": {
    "stream": "sdo",
    "type": "access_db",
    "input_type": "file",
    "table": "EXPORT_TABLE",
    "mapping": {
      "PK_ID": "numero_scheda"
    }
  },
  "sdo_campania_xml": {
    "stream": "sdo",
    "type": "xml",
    "input_type": "directory",
    "components": {
      "TblAnagrafica": "*_A.xml",
      "TblRicoveroICD9": "*_B.xml",
      "TblRicoveroICD10": "*_D.xml",
      "TblProcedures": "*_C.xml"
    }
  }
}
```

- [ ] **Step 2: Run validation script (Verify GREEN)**

Run: `node tests/validate_methods.js`
Expected: PASS

- [ ] **Step 3: Commit data changes**

```bash
git add data/methods.json
git commit -m "data: update methods.json with input_type and new sdo_campania_xml method"
```

### Task 4: Cleanup

- [ ] **Step 1: Remove temporary validation script if not needed or keep it**
I'll keep it for now as requested by TDD.

- [ ] **Step 2: Push changes (if branch exists)**
The user asked to commit on the `feat/complete-pipeline` branch. I should check if I need to create it.
