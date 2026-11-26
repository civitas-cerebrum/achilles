// Family N: API and database (test-baseline.md §Family N). TB-N1 HTTP outside the Steps API (blocking in specs,
// advisory in support), TB-N2 untyped responses in contract tests (advisory), TB-N4 database clients in specs.
// TB-N3 is judgment.
import { isCall, isMember, unwrap, isStr, strValue, propName, memberChain } from '../shapes.mjs';

const HTTP_CLIENTS = /^(axios|got|undici|node-fetch|cross-fetch|superagent|ky)(\/.*)?$/;
const DB_CLIENTS = /^(pg|pg-promise|postgres|mysql|mysql2|mysql2\/promise|sqlite3|better-sqlite3|mssql|tedious|oracledb|knex|typeorm|@prisma\/client|prisma|mongodb|mongoose|sequelize|drizzle-orm(\/.*)?|kysely|@civitas-cerebrum\/sql-client)$/;
const CONTRACTS = /^tests\/contracts\//;

export const RULES = [
  { id: 'TB-N1', title: 'HTTP outside the Steps API', severity: 'blocking', appliesTo: ['spec', 'support'], do: 'Send HTTP through steps.api* (own client) or steps.request* (the browser session); keep back-door HTTP in a support helper.' },
  { id: 'TB-N2', title: 'untyped response in a contract test', severity: 'advisory', appliesTo: ['spec'], do: 'Declare the response body type: steps.apiGet<Order>(…).' },
  { id: 'TB-N4', title: 'database client in a spec', severity: 'blocking', appliesTo: ['spec'], do: 'Reach the database through steps.sql* only; database helpers live in support modules.' },
];

export function visitors() {
  const sev = (ctx) => (ctx.file.kind === 'spec' ? 'blocking' : 'advisory');
  const suffix = (ctx) => (ctx.file.kind === 'spec' ? '' : ' (advisory in support: back-door, seeding and health checks are legitimate there)');

  function source(ctx, src, node) {
    if (HTTP_CLIENTS.test(src)) {
      ctx.report('TB-N1', node, { severity: sev(ctx), message: `imports the HTTP client ${src}${suffix(ctx)}` });
      return;
    }
    if (ctx.file.kind === 'spec' && DB_CLIENTS.test(src)) ctx.report('TB-N4', node, { message: `imports the database client ${src} in a spec` });
  }

  return {
    ImportDeclaration(n, ctx) {
      if (n.importKind !== 'type') source(ctx, n.source.value, n);
    },
    CallExpression(n, ctx) {
      const callee = unwrap(n.callee);
      if (callee.type === 'Identifier' && callee.name === 'require' && isStr(n.arguments[0])) { source(ctx, strValue(n.arguments[0]), n); return; }
      if (callee.type === 'Import' && isStr(n.arguments[0])) { source(ctx, strValue(n.arguments[0]), n); return; }
      const name = (memberChain(callee) || []).join('.');
      if (name === 'fetch' || name === 'globalThis.fetch' || name === 'window.fetch') { ctx.report('TB-N1', n, { severity: sev(ctx), message: `\`${name}(…)\` outside the Steps API${suffix(ctx)}` }); return; }
      if (CONTRACTS.test(ctx.file.rel) && isMember(callee) && ctx.kind(callee.object) === 'steps' && /^(api|request)[A-Z]/.test(propName(callee) || '') && !(n.typeParameters || n.typeArguments)) {
        ctx.report('TB-N2', n, { message: `steps.${propName(callee)}(…) without a response type in a contract test (advisory)` });
      }
    },
  };
}
