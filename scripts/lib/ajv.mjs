// The one Ajv configuration for every schema consumer (compile, fixtures, the
// bundled runtime validator), so they cannot disagree on strictness.
// `allowUnionTypes` admits the handover envelope's `cycle` (integer | string);
// `strictSchema: false` tolerates vendor keywords.
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

export function makeAjv() {
  const ajv = new (Ajv.default || Ajv)({
    strict: true,
    allErrors: true,
    loadSchema: false,
    allowUnionTypes: true,
    strictSchema: false,
  });
  (addFormats.default || addFormats)(ajv);
  return ajv;
}
