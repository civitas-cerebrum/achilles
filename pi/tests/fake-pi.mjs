export function makeFakePi() {
  const handlers = new Map();
  const tools = [];
  return {
    handlers, tools,
    on(event, fn) { handlers.set(event, [...(handlers.get(event) ?? []), fn]); return () => {}; },
    registerTool(def) { tools.push(def); },
    getAllTools() { return tools.map(t => ({ name: t.name })); },
    getActiveTools() { return tools.map(t => t.name); },
    events: { emit() {}, on() { return () => {}; } },
    async fire(event, payload, ctx) {
      let last;
      for (const fn of handlers.get(event) ?? []) last = await fn(payload, ctx);
      return last;
    },
  };
}
export function makeFakeCtx(over = {}) {
  const notices = [];
  const confirms = [];
  return {
    cwd: over.cwd ?? process.cwd(),
    hasUI: false, mode: 'print',
    ui: {
      notify(m, t) { notices.push({ m, t }); }, setStatus() {},
      /** Answers with over.confirmAnswer (default false) and records every dialog. */
      async confirm(title, message) { confirms.push({ title, message }); return over.confirmAnswer ?? false; },
    },
    notices, confirms,
    sessionManager: {
      getSessionId() { return over.sessionId ?? 'sid-1'; },
      getSessionFile() { return over.sessionFile; },
    },
    isProjectTrusted() { return over.trusted ?? true; },
    ...over,
  };
}
