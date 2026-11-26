// Family P: platform (test-baseline.md §Family P). These rules apply only to native-driver specs: a project whose
// tests drive a device through a native driver (a WebdriverIO or Appium dependency). On a web project they never
// fire. TB-P3 (declarative divergence) is TB-F1 on the platform branch.
import { isMember, isCall, unwrap, isStr, strValue, propName, propKey } from '../shapes.mjs';

const NATIVE_DEP = /^(webdriverio|appium|@wdio\/.+|appium-.+|@appium\/.+)$/;
const DRIVER_METHODS = /^(\$|\$\$|execute|executeScript|executeAsync|executeAsyncScript|touchAction|performActions|releaseActions|pause|getPageSource|keys|action|actions|tap|swipe|scroll|hideKeyboard|getContexts|switchContext)$/;
const CAPABILITY_KEY = /^(platformName|browserName|deviceName|udid|app|automationName)$|^appium:/;

export const RULES = [
  { id: 'TB-P1', title: 'raw driver call in a native-driver spec', severity: 'blocking', appliesTo: ['spec'], do: 'Drive the device through the Steps API, addressing elements by repository name.' },
  { id: 'TB-P2', title: 'capability literal in a native-driver spec', severity: 'blocking', appliesTo: ['spec'], do: "Keep capabilities in the config's projects; the spec reads steps.platform." },
];

/** True when the project drives a device through a native driver. */
export function nativeProject(pkg) {
  const deps = { ...(pkg?.dependencies || {}), ...(pkg?.devDependencies || {}) };
  return Object.keys(deps).some((d) => NATIVE_DEP.test(d));
}

export function visitors(project) {
  if (!nativeProject(project.pkg)) return {};
  return {
    CallExpression(n, ctx) {
      if (ctx.file.kind !== 'spec') return;
      const callee = unwrap(n.callee);
      if (isMember(callee)) {
        const recv = unwrap(callee.object);
        const name = recv.type === 'Identifier' ? recv.name : null;
        const p = propName(callee);
        if ((name === 'driver' || (name === 'browser' && DRIVER_METHODS.test(p || ''))) && !(isCall(recv))) { ctx.report('TB-P1', n, { message: `\`${name}.${p || '[computed]'}(…)\` drives the device through the driver object` }); return; }
      } else if (callee.type === 'Identifier' && (callee.name === '$' || callee.name === '$$')) { ctx.report('TB-P1', n, { message: `\`${callee.name}(…)\` reaches an element through the driver` }); return; }
      if (n.arguments.some((a) => isStr(unwrap(a)) && /^mobile:\s*\w/.test(strValue(unwrap(a))))) ctx.report('TB-P1', n, { message: 'a `mobile:` command string goes to the driver directly' });
    },
    ObjectExpression(n, ctx) {
      if (ctx.file.kind !== 'spec') return;
      const keys = n.properties.filter((p) => p.type === 'ObjectProperty').map(propKey).filter(Boolean);
      if (keys.some((k) => k === 'platformName' || k.startsWith('appium:')) && keys.filter((k) => CAPABILITY_KEY.test(k)).length >= 1) ctx.report('TB-P2', n, { message: `capability literal { ${keys.filter((k) => CAPABILITY_KEY.test(k)).join(', ')} } in a spec` });
    },
  };
}
