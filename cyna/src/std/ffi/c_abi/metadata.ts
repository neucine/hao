import type { FunctionSpec, PodSpec } from "std:ffi/c_abi/ast";
export type Prepared = { symbols: string[]; functions: FunctionSpec[]; policies: any; pods: Record<string, PodSpec> };
