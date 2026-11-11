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
async function hooks(nodes: Suite[], kind: HookKind): Promise<void> {
  for (const node of nodes) for (const hook of kind === 'after_each' ? [...node.hooks[kind]].reverse() : node.hooks[kind]) {
    globalThis.__hao_test_filePath = hook.file;
    await hook.fn();
  }
}
const ansiMode = getEnv('RUNTIME_TEST_REPORTER')?.toLowerCase() !== 'plain';
function styled(text: string, color: number): string {
  return ansiMode ? `\x1b[${color}m${text}\x1b[0m` : text;
}
function line(text = ''): void { globalThis.__hao_test_report(`${text}\n`); }
function duration(ns: number): string {
  const amount = Math.max(0, Math.floor(ns));
  if (amount < 1_000) return `${amount}ns`;
  const unit = amount < 1_000_000 ? 1_000 : amount < 1_000_000_000 ? 1_000_000 : 1_000_000_000;
  const suffix = unit === 1_000 ? 'us' : unit === 1_000_000 ? 'ms' : 's';
  return `${Math.floor(amount / unit)}.${String(Math.floor(amount % unit * 100 / unit)).padStart(2, '0')}${suffix}`;
}
function report(kind: 'PASS' | 'FAIL' | 'SKIP', item: Case, detail?: string): void {
  const depth = chain(item.suite).length;
  const glyph = kind === 'PASS' ? styled('✓', 32) : kind === 'FAIL' ? styled('✕', 31) : styled('↷', 33);
  const tail = kind === 'SKIP' ? ` (skipped: ${detail})` : ` (${detail})`;
  line(`${'  '.repeat(depth)}${glyph} ${item.name}${tail}`);
}

export async function runRegistered(): Promise<void> {
  const started = globalThis.__hao_test_started_ns ?? globalThis.__hao_telemetry_monotonicNs();
  const cases: Case[] = [];
  collect(root, cases);
  const hasOnly = cases.some(item => item.mode === 'only');
  const grep = globalThis.__hao_test_grep;
  let passed = 0, failed = 0, skipped = 0;
  let skippedDeclared = 0, skippedFiltered = 0, skippedBlocked = 0;
  const selected = cases.filter(item => item.mode !== 'skip' && (!hasOnly || item.mode === 'only') &&
    (!grep || item.name.includes(grep))).length;
  const declared = cases.filter(item => item.mode === 'skip').length;
  const filtered = cases.length - selected - declared;
  if (grep) line(`Filter: grep "${grep}"`);
  if (hasOnly) line('Filter: only mode');
  line(`Run ${selected}/${cases.length} test case(s)`);
  if (declared || filtered) line(`Skip before run: ${declared} declared, ${filtered} filtered`);
  line();
  const selectedCase = (item: Case): boolean => item.mode !== 'skip' &&
    (!hasOnly || item.mode === 'only') && (!grep || item.name.includes(grep));
  const hasSelected = (node: Suite): boolean => node.entries.some(entry =>
    'fn' in entry ? selectedCase(entry) : hasSelected(entry));
  const skipCase = (item: Case, blocked: boolean): void => {
    skipped++;
    const reason = selectedCase(item) && blocked ? 'beforeAll' :
      item.mode === 'skip' ? 'skip' : hasOnly ? 'only' : 'grep';
    if (reason === 'beforeAll') skippedBlocked++;
    else if (reason === 'skip') skippedDeclared++;
    else skippedFiltered++;
    report('SKIP', item, reason);
  };
  const message = (error: unknown): string => error instanceof Error ? error.message : String(error);
  const hookFailure = (node: Suite, kind: 'beforeAll' | 'afterAll', error: unknown): void => {
    failed++;
    const depth = chain(node).length;
    line(`${'  '.repeat(depth)}${styled('✕', 31)} ${kind}`);
    line(`${'  '.repeat(depth + 1)}${kind} failed: ${message(error)}`);
  };
  const runCase = async (item: Case): Promise<void> => {
    globalThis.__hao_test_filePath = item.file;
    const nodes = chain(item.suite);
    const caseStarted = globalThis.__hao_telemetry_monotonicNs();
    let error: unknown = null;
    let caseFailed = false;
    let completedScopes = 0;
    for (const node of nodes) {
      try { await hooks([node], 'before_each'); completedScopes++; }
      catch (caught) { error = caught; caseFailed = true; break; }
    }
    if (!caseFailed) {
      try { await item.fn(); }
      catch (caught) { error = caught; caseFailed = true; }
    }
    for (const node of nodes.slice(0, completedScopes).reverse()) {
      try { await hooks([node], 'after_each'); }
      catch (caught) {
        if (!caseFailed) { error = caught; caseFailed = true; }
        else line(`${'  '.repeat(nodes.length + 1)}afterEach failed: ${message(caught)}`);
      }
    }
    if (caseFailed) {
      failed++;
      report('FAIL', item, duration(globalThis.__hao_telemetry_monotonicNs() - caseStarted));
      line(`${'  '.repeat(nodes.length + 1)}test failed: ${message(error)}`);
    } else {
      passed++;
      report('PASS', item, duration(globalThis.__hao_telemetry_monotonicNs() - caseStarted));
    }
  };
  const runSuite = async (node: Suite, blocked = false): Promise<void> => {
    if (node !== root) line(`${'  '.repeat(chain(node).length - 1)}${node.name}`);
    const active = hasSelected(node);
    if (!active || blocked) {
      for (const entry of node.entries) {
        if ('fn' in entry) skipCase(entry, blocked);
        else await runSuite(entry, blocked);
      }
      return;
    }
    let beforeFailed = false;
    try { await hooks([node], 'before_all'); }
    catch (error) { hookFailure(node, 'beforeAll', error); beforeFailed = true; }
    for (const entry of node.entries) {
      if ('fn' in entry) {
        if (beforeFailed || !selectedCase(entry)) skipCase(entry, beforeFailed);
        else await runCase(entry);
      } else await runSuite(entry, beforeFailed);
    }
    try { await hooks([node], 'after_all'); }
    catch (error) { hookFailure(node, 'afterAll', error); }
  };
  await runSuite(root);
  const files = globalThis.__hao_test_file_counts ?? { loaded: 0, failed: 0, total: 0 };
  line();
  line(`${styled('Test Files:', 1)} ${files.loaded} loaded, ${files.failed} failed, ${files.total} total`);
  line(`${styled('Tests:', 1)} ${passed} passed, ${failed} failed, ${skipped} skipped`);
  line(`${styled('Time:', 1)} ${duration(globalThis.__hao_telemetry_monotonicNs() - started)}`);
  if (skipped) line(`${styled('Skipped:', 1)} ${skippedDeclared} declared, ${skippedFiltered} filtered, ${skippedBlocked} blocked`);
  globalThis.__hao_test_failed = failed;
}

globalThis.__hao_test_run = runRegistered;
globalThis.__hao_test_discardFile = discardTestFile;
