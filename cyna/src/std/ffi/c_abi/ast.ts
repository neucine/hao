export type PodField = { name: string; type: string; offset: number; pod?: string };
export type PodSpec = { fields: PodField[]; size: number; alignment: number };
export type Parameter = { name: string; type: string; pod?: string };
export type FunctionSpec = { name: string; params: Parameter[]; returns: string };
