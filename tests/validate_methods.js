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
