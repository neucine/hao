type HookKind = 'before_all' | 'after_all' | 'before_each' | 'after_each';
type Mode = 'normal' | 'skip' | 'only';
type Case = { name: string; fn: () => unknown; mode: Mode; suite: Suite; file: string };
type Hook = { fn: () => unknown; file: string };
type Suite = { name: string; parent: Suite | null; entries: Array<Suite | Case>; hooks: Record<HookKind, Hook[]> };

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
  current.hooks[kind].push({ fn, file: getCurrentTestFilePath() });
  registeredHooks++;
}
export function getCurrentTestFilePath(): string { return globalThis.__hao_test_filePath ?? ''; }
export function getCurrentExecutablePath(): string { return globalThis.__hao_test_executablePath ?? ''; }
export function beginCapture(target = 'stdout'): void { globalThis.__hao_test_beginCapture(target); }
export function endCapture(): { stdout: string; stderr: string; combined: string } { return globalThis.__hao_test_endCapture(); }
export function getRegisteredCounts() {
  let count = 0;
  const visit = (node: Suite) => { for (const entry of node.entries) { if ('fn' in entry) count++; else visit(entry); } };
  visit(root);
  const deepest = (node: Suite, depth: number): number => {
    let maximum = depth;
    for (const entry of node.entries) if (!('fn' in entry)) maximum = Math.max(maximum, deepest(entry, depth + 1));
    return maximum;
  };
  return { registeredTests: count, registeredHooks, suiteDepth: deepest(root, 0) };
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
  for (const node of nodes) for (const hook of node.hooks[kind]) {
    globalThis.__hao_test_filePath = hook.file;
    await hook.fn();
  }
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
