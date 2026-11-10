type HookKind = 'before_all' | 'after_all' | 'before_each' | 'after_each';
type Mode = 'normal' | 'skip' | 'only';
type Case = { name: string; fn: () => unknown; mode: Mode; suite: Suite; file: string };
type Suite = { name: string; parent: Suite | null; entries: Array<Suite | Case>; hooks: Record<HookKind, Array<() => unknown>> };

function suite(name: string, parent: Suite | null): Suite {
  return { name, parent, entries: [], hooks: { before_all: [], after_all: [], before_each: [], after_each: [] } };
}
const root = suite('', null);
let current = root;
let registeredHooks = 0;

export function pushSuite(name: string): void {
  const child = suite(name, current);
  current.entries.push(child);
  current = child;
}
export function popSuite(): void {
  if (!current.parent) throw Error('No test suite to close');
  current = current.parent;
}
export function registerTest(name: string, fn: () => unknown, mode: Mode): void {
  current.entries.push({ name, fn, mode, suite: current, file: getCurrentTestFilePath() });
}
export function registerHook(kind: HookKind, fn: () => unknown): void {
  current.hooks[kind].push(fn);
  registeredHooks++;
}
export function getCurrentTestFilePath(): string { return globalThis.__hao_test_filePath ?? ''; }
export function getCurrentExecutablePath(): string { return globalThis.__hao_test_executablePath ?? ''; }
export function beginCapture(): void { throw Error('std:test captureOutput is not available yet'); }
export function endCapture(): never { throw Error('std:test captureOutput is not available yet'); }
export function getRegisteredCounts() {
  let count = 0;
  const visit = (node: Suite) => { for (const entry of node.entries) { if ('fn' in entry) count++; else visit(entry); } };
  visit(root);
  let depth = 0;
  for (let node: Suite | null = current; node?.parent; node = node.parent) depth++;
  return { registeredTests: count, registeredHooks, suiteDepth: depth };
}

function chain(node: Suite): Suite[] {
  const result: Suite[] = [];
  for (let part: Suite | null = node; part; part = part.parent) result.unshift(part);
  return result;
}
function collect(node: Suite, result: Case[]): void {
  for (const entry of node.entries) {
    if ('fn' in entry) result.push(entry);
    else collect(entry, result);
  }
}
function qualifiedName(item: Case): string {
  return [...chain(item.suite).map(part => part.name).filter(Boolean), item.name].join(' > ');
}
async function hooks(nodes: Suite[], kind: HookKind): Promise<void> {
  for (const node of nodes) for (const hook of node.hooks[kind]) await hook();
}

export async function runRegistered(): Promise<void> {
  const cases: Case[] = [];
  collect(root, cases);
  const hasOnly = cases.some(item => item.mode === 'only');
  const grep = globalThis.__hao_test_grep;
  const entered = new Set<Suite>();
  let passed = 0, failed = 0, skipped = 0;
  console.log(`Found ${cases.length} test case(s)`);
  for (const item of cases) {
    globalThis.__hao_test_filePath = item.file;
    const name = qualifiedName(item);
    if (item.mode === 'skip' || hasOnly && item.mode !== 'only' || grep && !name.includes(grep)) {
      skipped++;
      console.log(`SKIP ${name}`);
      continue;
    }
    const nodes = chain(item.suite);
    let error: unknown = null;
    try {
      for (const node of nodes) {
        if (!entered.has(node)) { entered.add(node); await hooks([node], 'before_all'); }
      }
      await hooks(nodes, 'before_each');
      await item.fn();
    } catch (caught) { error = caught; }
    try { await hooks([...nodes].reverse(), 'after_each'); }
    catch (caught) { if (!error) error = caught; }
    if (error) {
      failed++;
      console.log(`FAIL ${name}: ${error}`);
    } else {
      passed++;
      console.log(`PASS ${name}`);
    }
  }
  for (const node of [...entered].reverse()) {
    try { await hooks([node], 'after_all'); }
    catch (error) { failed++; console.log(`FAIL afterAll ${node.name}: ${error}`); }
  }
  console.log(`${passed} passed, ${failed} failed, ${skipped} skipped`);
  globalThis.__hao_test_failed = failed;
}

globalThis.__hao_test_run = runRegistered;
