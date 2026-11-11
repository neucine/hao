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
  return {
    maxDepth: limit(options?.maxDepth, defaults.maxDepth),
    maxArrayLength: limit(options?.maxArrayLength, defaults.maxArrayLength),
    maxStringLength: limit(options?.maxStringLength, defaults.maxStringLength),
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
  const truncate = (text: string) => text.length > opts.maxStringLength
    ? text.slice(0, opts.maxStringLength) + "..." : text;

  function format(item: any, depth: number): string {
    if (typeof item === "string") return truncate(item);
    if (item === null) return "null";
    if (typeof item !== "object" && typeof item !== "function") return String(item);
    if (depth >= opts.maxDepth) return "[Object]";

    try {
      const reprMethod = item.repr;
      if (typeof reprMethod === "function") {
        const repr = reprMethod.call(item, { mode: "text" });
        const data = repr && typeof repr === "object" ? repr.data : repr;
        if (data !== null && data !== undefined && typeof data !== "symbol") return truncate(String(data));
      }
    } catch (_) { /* Fall back to ordinary inspection. */ }
    try {
      if (item.dtype != null && item.shape != null && typeof item.toString === "function") return String(item);
    } catch (_) { return ""; }
    if (typeof item === "function") return item.name ? `[Function: ${item.name}]` : "[Function]";
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
