/** C and Cyna host functions injected into the embedded JavaScript runtime. */
declare var __hao_ffi_open: (name: string) => number;
declare var __hao_ffi_bind: (handle: number, symbol: string, args: string[], returns: string) => void;
declare var __hao_ffi_call: (handle: number, symbol: string, args: unknown[], outIndex?: number) => any;
declare var __hao_ffi_close: (handle: number) => void;

declare var __hao_fs_existsSync: (...args: any[]) => any;
declare var __hao_fs_readFileSync: (...args: any[]) => any;
declare var __hao_fs_statSync: (...args: any[]) => any;
declare var __hao_fs_writeFileSync: (...args: any[]) => any;

declare var __hao_http_requestNative: (options: any) => Promise<any>;
declare var __hao_http_serveNative: (options: any, callback: (id: number, chunk: Uint8Array | null) => void) => { id: number; port: number };
declare var __hao_http_stopServerNative: (id: number) => void;
declare var __hao_http_pauseClientNative: (id: number) => void;
declare var __hao_http_respondNative: (id: number, bytes: Uint8Array) => void;
declare var __hao_http_unrefServerNative: (id: number) => void;
declare var __hao_http_encodeTextNative: (value: string) => Uint8Array;
declare var __hao_http_decodeTextNative: (value: Uint8Array) => string;

declare var __hao_process_getEnvNative: (...args: any[]) => any;
declare var __hao_process_runNative: (...args: any[]) => any;
declare var __hao_telemetry_memorySnapshot: () => Record<string, number>;
interface HaoTraceContext { span: number | null; trace: string | null; spanId: string | null }
declare var __hao_telemetry_captureContext: () => HaoTraceContext;
declare var __hao_telemetry_enterContext: (context: HaoTraceContext) => HaoTraceContext;

declare var __hao_test_beginCapture: (...args: any[]) => any;
declare var __hao_test_endCapture: (...args: any[]) => any;
declare var __hao_test_executablePath: string;
declare var __hao_test_failed: number;
declare var __hao_test_filePath: string;
declare var __hao_test_grep: string;
declare var __hao_test_run: (...args: any[]) => any;
declare var __hao_test_report: (text: string) => void;
declare var __hao_test_file_counts: { loaded: number; failed: number; total: number };
declare var __hao_test_started_ns: number;
declare var __hao_telemetry_monotonicNs: () => number;
