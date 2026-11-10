import { getEnv } from 'std:process';

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

export function discardTestFile(path: string): void {
  const discard = (node: Suite): void => {
    for (const kind of ['before_all', 'after_all', 'before_each', 'after_each'] as HookKind[]) {
      const before = node.hooks[kind].length;
      node.hooks[kind] = node.hooks[kind].filter(hook => hook.file !== path);
      registeredHooks -= before - node.hooks[kind].length;
    }
    node.entries = node.entries.filter(entry => {
      if ('fn' in entry) return entry.file !== path;
      discard(entry);
      return entry.entries.length > 0 || Object.values(entry.hooks).some(hooks => hooks.length > 0);
    });
  };
  discard(root);
  current = root;
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
  for (const node of nodes) for (const hook of kind === 'after_each' ? [...node.hooks[kind]].reverse() : node.hooks[kind]) {
    globalThis.__hao_test_filePath = hook.file;
    await hook.fn();
  }
}
function report(kind: 'PASS' | 'FAIL' | 'SKIP', detail: string): void {
  const mode = getEnv('RUNTIME_TEST_REPORTER');
  const color = kind === 'PASS' ? 32 : kind === 'FAIL' ? 31 : 33;
  const label = mode?.toLowerCase() === 'ansi' ? `\x1b[${color}m${kind}\x1b[0m` : kind;
  console.log(`${label} ${detail}`);
}

export async function runRegistered(): Promise<void> {
  const started = Date.now();
  const cases: Case[] = [];
  collect(root, cases);
  const hasOnly = cases.some(item => item.mode === 'only');
  const grep = globalThis.__hao_test_grep;
  const entered = new Set<Suite>();
  const blocked = new Set<Suite>();
  let passed = 0, failed = 0, skipped = 0;
  let skippedDeclared = 0, skippedFiltered = 0, skippedBlocked = 0;
  console.log(`Found ${cases.length} test case(s)`);
  for (const item of cases) {
    globalThis.__hao_test_filePath = item.file;
    const name = qualifiedName(item);
    if (item.mode === 'skip' || hasOnly && item.mode !== 'only' || grep && !item.name.includes(grep)) {
      skipped++;
      if (item.mode === 'skip') skippedDeclared++; else skippedFiltered++;
      report('SKIP', name);
      continue;
    }
    const nodes = chain(item.suite);
    let error: unknown = null;
    let caseFailed = false;
    let completedScopes = 0;
    let blockedCase = false;
    try {
      for (const node of nodes) {
        if (blocked.has(node)) {
          skipped++;
          skippedBlocked++;
          report('SKIP', `${name} (beforeAll)`);
          blockedCase = true;
          break;
        }
        if (!entered.has(node)) {
          entered.add(node);
          try { await hooks([node], 'before_all'); }
          catch (caught) { blocked.add(node); throw caught; }
        }
      }
      if (blockedCase) continue;
      for (const node of nodes) {
        await hooks([node], 'before_each');
        completedScopes++;
      }
      await item.fn();
    } catch (caught) { error = caught; caseFailed = true; }
    for (const node of nodes.slice(0, completedScopes).reverse()) {
      try { await hooks([node], 'after_each'); }
      catch (caught) { if (!caseFailed) { error = caught; caseFailed = true; } }
    }
    if (caseFailed) {
      failed++;
      report('FAIL', `${name}: ${error}`);
    } else {
      passed++;
      report('PASS', name);
    }
  }
  for (const node of [...entered].reverse()) {
    try { await hooks([node], 'after_all'); }
    catch (error) { failed++; report('FAIL', `afterAll ${node.name}: ${error}`); }
  }
  console.log(`Time: ${Date.now() - started}ms`);
  if (skipped) console.log(`Skipped: ${skippedDeclared} declared, ${skippedFiltered} filtered, ${skippedBlocked} blocked`);
  console.log(`${passed} passed, ${failed} failed, ${skipped} skipped`);
  globalThis.__hao_test_failed = failed;
}

globalThis.__hao_test_run = runRegistered;
globalThis.__hao_test_discardFile = discardTestFile;
