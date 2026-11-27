// Stand-in for pi's own packages (@earendil-works/pi-ai and friends), which pi hands an extension
// through its loader's alias map. Only what pi/index.ts uses at runtime: typebox's Type builders.
const schema = (kind) => (...args) => ({ kind, args });
export const Type = { Object: schema('Object'), String: schema('String'), Optional: schema('Optional') };
