export interface InspectOptions {
  maxDepth?: number;
  maxArrayLength?: number;
  maxStringLength?: number;
}

let defaults = { maxDepth: 4, maxArrayLength: 100, maxStringLength: 10000 };

function limit(value: unknown, fallback: number): number {
  if (typeof value !== "number") return fallback;
  if (Number.isNaN(value)) return 0;
  if (!Number.isFinite(value) || value >= 18446744073709551616) return Infinity;
  return Math.max(0, Math.floor(value));
}

function merge(options?: InspectOptions) {
  const read = (key: keyof InspectOptions, fallback: number) => {
    try { return limit(options?.[key], fallback); }
    catch (_) { return fallback; }
  };
  return {
    maxDepth: read('maxDepth', defaults.maxDepth),
    maxArrayLength: read('maxArrayLength', defaults.maxArrayLength),
    maxStringLength: read('maxStringLength', defaults.maxStringLength),
  };
}

export function setInspectOptions(options: InspectOptions): void {
  defaults = merge(options);
}

export function getInspectOptions(): InspectOptions {
  return { ...defaults };
}

export function inspect(value: unknown, options?: InspectOptions): string {
  if (arguments.length === 0) return undefined as any;
  const opts = merge(options);
  const seen = new Set<object>();
  const truncate = (text: string) => {
    if (opts.maxStringLength === Infinity || !/[^\x00-\x7f]/.test(text)) {
      return text.length > opts.maxStringLength ? text.slice(0, opts.maxStringLength) + "..." : text;
    }
    let normalized = "";
    for (let index = 0; index < text.length; index++) {
      const unit = text.charCodeAt(index);
      if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < text.length) {
        const next = text.charCodeAt(index + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          normalized += text.slice(index, index + 2);
          index++;
          continue;
        }
      }
      normalized += unit >= 0xd800 && unit <= 0xdfff ? "\uFFFD" : text[index];
    }
    const bytes = unescape(encodeURIComponent(normalized));
    if (bytes.length <= opts.maxStringLength) return text;
    const prefix = bytes.slice(0, opts.maxStringLength);
    for (let length = prefix.length; length >= 0; length--) {
      try { return decodeURIComponent(escape(prefix.slice(0, length))) + "\uFFFD".repeat(prefix.length - length) + "..."; }
      catch (_) { /* The byte limit cut through a UTF-8 sequence. */ }
    }
    return "...";
  };

  function format(item: any, depth: number): string {
    if (typeof item === "string") return truncate(item);
    if (item === null) return "null";
    if (typeof item === "symbol") return "";
    if (typeof item !== "object" && typeof item !== "function") return String(item);
    if (depth >= opts.maxDepth) return "[Object]";

    try {
      const reprMethod = item.repr;
      if (typeof reprMethod === "function") {
        const repr = item.repr.call(item, { mode: "text" });
        const data = repr && typeof repr === "object" ? repr.data : repr;
        if (data !== null && data !== undefined && typeof data !== "symbol") return truncate(String(data));
      }
    } catch (_) { /* Fall back to ordinary inspection. */ }
    const failed = {};
    const property = (key: string) => {
      try { return item[key]; }
      catch (_) { return failed; }
    };
    if (property('dtype') != null && property('shape') != null && typeof property('toString') === "function") {
      try { return String(item); }
      catch (_) { return ""; }
    }
    if (typeof item === "function") {
      try { const name = item.name; return typeof name === "string" && name ? `[Function: ${name}]` : "[Function]"; }
      catch (_) { return "[Function]"; }
    }
    if (seen.has(item)) return "[Circular]";
    seen.add(item);
    try {
      const array = Array.isArray(item);
      let keys: any;
      try { keys = array ? item : Object.keys(item); }
      catch (_) { return array ? "[ ]" : "{ }"; }
      const count = Math.min(keys.length, opts.maxArrayLength);
      const entries: string[] = [];
      for (let index = 0; index < count; index++) {
        let rendered = "";
        try { rendered = format(item[array ? index : keys[index]], depth + 1); }
        catch (_) { /* Zig appends no value on conversion failure. */ }
        entries.push(array ? rendered : `${keys[index]}: ${rendered}`);
      }
      if (keys.length > count) entries.push(`... ${keys.length - count} more items`);
      return array ? `[ ${entries.join(", ")} ]` : `{ ${entries.join(", ")} }`;
    } finally {
      seen.delete(item);
    }
  }
  return format(value, 0);
}

export default { inspect, setInspectOptions, getInspectOptions };
