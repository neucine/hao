declare module "std:ffi" {
  type FFIType = 'void' | 'bool'
    | 'i8' | 'i16' | 'i32' | 'i64'
    | 'u8' | 'u16' | 'u32' | 'u64'
    | 'f32' | 'f64'
    | 'ptr' | 'cstring' | 'buffer';

  interface Pointer {
    readonly __brand: unique symbol;
  }

  type MapFFIType<T extends FFIType> =
    T extends 'void' ? void :
    T extends 'bool' ? boolean :
    T extends 'cstring' ? string :
    T extends 'ptr' | 'buffer' ? Pointer :
    number;

  type MapReturnType<T extends FFIType> = MapFFIType<T>;

  type MapArgTypes<T extends readonly FFIType[]> =
    T extends readonly [infer H extends FFIType, ...infer R extends FFIType[]]
      ? [MapFFIType<H>, ...MapArgTypes<R>]
      : [];

  interface FnDescriptor {
    args: readonly FFIType[];
    returns: FFIType;
  }

  type LibraryFunctions<T extends Record<string, FnDescriptor>> = {
    [K in keyof T]: (...args: MapArgTypes<T[K]['args']>) => MapReturnType<T[K]['returns']>;
  } & {
    /** Close the loaded dynamic library. */
    close(): void;
  };

  /**
   * Load a dynamic library and bind typed symbols.
   * @example const lib = dlopen('libm', { sqrt: { args: ['f64'], returns: 'f64' } })
   */
  function dlopen<const T extends Record<string, FnDescriptor>>(
    name: string,
    symbols: T,
  ): LibraryFunctions<T>;

  interface CHandle<TypeName extends string = string> {
    readonly __ptr: number;
    readonly __type: TypeName;
    close(): void;
  }

  interface CHandlePolicy {
    /**
     * Symbol used to release handles of this type when `close()` is called.
     */
    close?: string;
  }

  interface CFunctionReturnPolicy {
    /**
     * Wrap a native pointer return as a managed opaque handle.
     */
    kind?: "handle";
    /**
     * Handle type name used to look up `handles[...]` policy.
     */
    type?: string;
    /**
     * Lift a hidden `T** out` parameter into the JS return value.
     */
    out?: string;
  }

  interface CMessageFunctionSource {
    /**
     * Symbol invoked to fetch an error message after the main native call fails.
     */
    from: string;
    /**
     * Function parameter name forwarded to `from(...)`.
     * This may refer to a lifted out-parameter.
     */
    arg?: string;
  }

  interface CFunctionErrorPolicy {
    kind?: "status" | "null" | "sentinel";
    /**
     * Success value for `status`-style APIs.
     */
    ok?: number;
    /**
     * Failure sentinel for `sentinel`-style APIs.
     */
    value?: number;
    /**
     * `RuntimeError.code` used when the native call fails.
     */
    code?: string;
    /**
     * Static message or helper-function source for the thrown `RuntimeError`.
     */
    message?: string | CMessageFunctionSource;
  }

  interface CBufferPolicy {
    /**
     * Companion length parameter name hidden from the JS call surface.
     */
    length: string;
    /**
     * Element type used to convert backing-byte length into element count.
     */
    element:
      | "u8"
      | "i8"
      | "u16"
      | "i16"
      | "u32"
      | "i32"
      | "u64"
      | "i64"
      | "f32"
      | "f64";
    /**
     * Direction hint for wrapper authors. The current runtime accepts caller-
     * allocated typed-array storage for all three cases.
     */
    direction?: "in" | "out" | "inout";
  }

  interface CFunctionPolicy {
    returns?: CFunctionReturnPolicy;
    /**
     * Pointer-plus-length buffer policies keyed by pointer parameter name.
     */
    buffers?: Record<string, CBufferPolicy>;
    errors?: CFunctionErrorPolicy;
  }

  interface CSearchOptions {
    /**
     * Search order used when resolving non-explicit library names.
     */
    strategy?: "runtime-default" | "relative-first" | "system-first";
    /**
     * Additional directories searched for the target shared library.
     */
    paths?: readonly string[];
  }

  interface CDeclOptions {
    handles?: Record<string, CHandlePolicy>;
    functions?: Record<string, CFunctionPolicy>;
    search?: CSearchOptions;
  }

  type CBufferInputForElement<Element extends CBufferPolicy["element"]> =
    ArrayBuffer |
    (
      Element extends "u8" ? Uint8Array :
      Element extends "i8" ? Int8Array :
      Element extends "u16" ? Uint16Array :
      Element extends "i16" ? Int16Array :
      Element extends "u32" ? Uint32Array :
      Element extends "i32" ? Int32Array :
      Element extends "u64" ? BigUint64Array :
      Element extends "i64" ? BigInt64Array :
      Element extends "f32" ? Float32Array :
      Element extends "f64" ? Float64Array :
      never
    );

  type CWhitespace = " " | "\n" | "\t" | "\r";

  type CTrimLeft<S extends string> = S extends `${CWhitespace}${infer Rest}` ? CTrimLeft<Rest> : S;
  type CTrimRight<S extends string> = S extends `${infer Rest}${CWhitespace}` ? CTrimRight<Rest> : S;
  type CTrim<S extends string> = CTrimLeft<CTrimRight<S>>;

  type CLastToken<S extends string> =
    CTrim<S> extends `${infer _Head} ${infer Tail}` ? CLastToken<Tail> :
    CTrim<S> extends `${infer _Head}\n${infer Tail}` ? CLastToken<Tail> :
    CTrim<S> extends `${infer _Head}\t${infer Tail}` ? CLastToken<Tail> :
    CTrim<S>;

  type CFunctionNameFromStatement<Stmt extends string> =
    CTrim<Stmt> extends `typedef ${string}` ? never :
    CTrim<Stmt> extends `${infer Head}(${string}` ? CLastToken<Head> :
    never;

  type CFunctionNames<Decls extends string> =
    Decls extends `${infer Stmt};${infer Rest}`
      ? CFunctionNameFromStatement<Stmt> | CFunctionNames<Rest>
      : CFunctionNameFromStatement<Decls>;

  type CFindFunctionStatement<Decls extends string, Name extends string> =
    Decls extends `${infer Stmt};${infer Rest}`
      ? CFunctionNameFromStatement<Stmt> extends Name
        ? CTrim<Stmt>
        : CFindFunctionStatement<Rest, Name>
      : CFunctionNameFromStatement<Decls> extends Name
        ? CTrim<Decls>
        : never;

  type COpaqueHandleNameFromStatement<Stmt extends string> =
    CTrim<Stmt> extends `typedef struct ${infer Name} ${infer Alias}`
      ? CTrim<Name> extends CTrim<Alias> ? CTrim<Name> : never
      : never;

  type COpaqueHandleNames<Decls extends string> =
    Decls extends `${infer Stmt};${infer Rest}`
      ? COpaqueHandleNameFromStatement<Stmt> | COpaqueHandleNames<Rest>
      : COpaqueHandleNameFromStatement<Decls>;

  type CPodStructNameFromStatement<Stmt extends string> =
    CTrim<Stmt> extends `typedef struct {${string}} ${infer Name}` ? CTrim<Name> : never;

  type CPodStructBodyForName<Decls extends string, Name extends string> =
    CTrim<Decls> extends `typedef struct {${infer Body}} ${infer DeclName};${infer Rest}`
      ? CTrim<DeclName> extends Name ? Body : CPodStructBodyForName<Rest, Name>
      : CTrim<Decls> extends `typedef struct {${infer Body}} ${infer DeclName}`
        ? CTrim<DeclName> extends Name ? Body : never
        : CTrim<Decls> extends `${infer _First}${infer Rest}`
          ? CPodStructBodyForName<Rest, Name>
          : never;

  type CIsPodStructName<Decls extends string, Name extends string> =
    [CPodStructBodyForName<Decls, Name>] extends [never] ? false : true;

  type CParamsFromStatement<Stmt extends string> =
    Stmt extends `${string}(${infer Params})` ? Params : never;

  type CFunctionParamsForName<Decls extends string, Name extends string> =
    Decls extends `${string}${Name}(${infer Params});${string}` ? Params :
    Decls extends `${string}${Name}(${infer Params})` ? Params :
    never;

  type CReturnChunkFromStatement<Stmt extends string, Name extends string> =
    Stmt extends `${infer Head}${Name}(${string}` ? CTrim<Head> : never;

  type CFieldName<Field extends string> = CLastToken<Field>;

  type CFieldTypeChunk<Field extends string> =
    CTrim<CStripSuffix<CTrim<Field>, CFieldName<Field>>>;

  type CFieldTypeValue<
    Decls extends string,
    Chunk extends string,
  > =
    CTrim<Chunk> extends "bool" ? boolean :
    CTrim<Chunk> extends `${string}char*` ? string :
    CTrim<Chunk> extends `${string}char *` ? string :
    CTrim<Chunk> extends `${infer TypeName}*` ? CMapPointerParamTypeForDecls<Decls, CTrim<TypeName>> :
    CTrim<Chunk> extends `${infer TypeName} *` ? CMapPointerParamTypeForDecls<Decls, CTrim<TypeName>> :
    CIsPodStructName<Decls, CTrim<Chunk>> extends true ? CPodStructShape<Decls, CTrim<Chunk>> :
    number;

  type CPodStructFields<
    Decls extends string,
    Body extends string,
  > =
    Body extends `${infer Field};${infer Rest}`
      ? CTrim<Field> extends ""
        ? CPodStructFields<Decls, Rest>
        : { [K in CFieldName<Field>]: CFieldTypeValue<Decls, CFieldTypeChunk<Field>> } & CPodStructFields<Decls, Rest>
      : CTrim<Body> extends ""
        ? {}
        : { [K in CFieldName<Body>]: CFieldTypeValue<Decls, CFieldTypeChunk<Body>> };

  type CPodStructShape<
    Decls extends string,
    Name extends string,
  > = CPodStructFields<Decls, CPodStructBodyForName<Decls, Name>>;

  type CDirectReturnFromChunk<Decls extends string, Chunk extends string> =
    CTrim<Chunk> extends "void" ? void :
    CTrim<Chunk> extends "bool" ? boolean :
    CTrim<Chunk> extends `${string}char*` ? string | null :
    CTrim<Chunk> extends `${string}char *` ? string | null :
    CIsPodStructName<Decls, CTrim<Chunk>> extends true ? CPodStructShape<Decls, CTrim<Chunk>> :
    CTrim<Chunk> extends `${string}*` ? number :
    number;

  type CFindOutParamNamedType<Params extends string, OutName extends string> =
    Params extends `${infer Param},${infer Rest}`
      ? CFindOutParamNamedTypeInParam<Param, OutName> extends never
        ? CFindOutParamNamedType<Rest, OutName>
        : CFindOutParamNamedTypeInParam<Param, OutName>
      : CFindOutParamNamedTypeInParam<Params, OutName>;

  type CFindOutParamNamedTypeInParam<Param extends string, OutName extends string> =
    CTrim<Param> extends `${infer Type}** ${OutName}` ? CLastToken<Type> :
    CTrim<Param> extends `${infer Type} ** ${OutName}` ? CLastToken<Type> :
    never;

  type CFunctionPolicyFor<
    Opts extends CDeclOptions | undefined,
    Name extends string,
  > =
    Opts extends { functions: infer Functions extends Record<string, CFunctionPolicy> }
      ? Name extends keyof Functions ? Functions[Name] : undefined
      : undefined;

  type CBufferPolicyForParam<
    Policy extends CFunctionPolicy | undefined,
    ParamName extends string,
  > =
    Policy extends { buffers: infer Buffers extends Record<string, CBufferPolicy> }
      ? ParamName extends keyof Buffers ? Buffers[ParamName] : undefined
      : undefined;

  type CBufferLengthNames<Policy extends CFunctionPolicy | undefined> =
    Policy extends { buffers: infer Buffers extends Record<string, CBufferPolicy> }
      ? {
          [Key in keyof Buffers]: Buffers[Key] extends { length: infer Length extends string } ? Length : never
        }[keyof Buffers]
      : never;

  type CIsHiddenParam<
    Policy extends CFunctionPolicy | undefined,
    ParamName extends string,
  > =
    Policy extends { returns: { out: infer OutName extends string } }
      ? ParamName extends OutName ? true : ParamName extends CBufferLengthNames<Policy> ? true : false
      : ParamName extends CBufferLengthNames<Policy> ? true : false;

  type CParamName<Param extends string> =
    CLastToken<Param>;

  type CStripSuffix<S extends string, Suffix extends string> =
    S extends `${infer Head}${Suffix}` ? Head : never;

  type CParamTypeChunk<Param extends string> =
    CTrim<CStripSuffix<CTrim<Param>, CParamName<Param>>>;

  type CMapDirectParamType<Chunk extends string> =
    CTrim<Chunk> extends "bool" ? boolean :
    CTrim<Chunk> extends `${string}char*` ? string :
    CTrim<Chunk> extends `${string}char *` ? string :
    CTrim<Chunk> extends `${infer Type}*` ? CMapPointerParamType<CTrim<Type>> :
    CTrim<Chunk> extends `${infer Type} *` ? CMapPointerParamType<CTrim<Type>> :
    number;

  type CMapPointerParamType<TypeName extends string> =
    TypeName extends COpaqueHandleNames<any> ? CHandle<TypeName> | number :
    number;

  type CMapPointerParamTypeForDecls<
    Decls extends string,
    TypeName extends string,
  > =
    TypeName extends COpaqueHandleNames<Decls> ? CHandle<TypeName> | number :
    CIsPodStructName<Decls, TypeName> extends true ? CPodStructShape<Decls, TypeName> | number :
    number;

  type CParamValueType<
    Decls extends string,
    Policy extends CFunctionPolicy | undefined,
    Param extends string,
  > =
    CBufferPolicyForParam<Policy, CParamName<Param>> extends { element: infer Element extends CBufferPolicy["element"] } ? CBufferInputForElement<Element> :
    CTrim<CParamTypeChunk<Param>> extends "bool" ? boolean :
    CTrim<CParamTypeChunk<Param>> extends `${string}char*` ? string :
    CTrim<CParamTypeChunk<Param>> extends `${string}char *` ? string :
    CIsPodStructName<Decls, CTrim<CParamTypeChunk<Param>>> extends true ? CPodStructShape<Decls, CTrim<CParamTypeChunk<Param>>> :
    CTrim<CParamTypeChunk<Param>> extends `${infer TypeName}*` ? CMapPointerParamTypeForDecls<Decls, CTrim<TypeName>> :
    CTrim<CParamTypeChunk<Param>> extends `${infer TypeName} *` ? CMapPointerParamTypeForDecls<Decls, CTrim<TypeName>> :
    number;

  type CParamTuple<
    Decls extends string,
    Policy extends CFunctionPolicy | undefined,
    Params extends string,
  > =
    [CTrim<Params>] extends [""]
      ? []
      : Params extends `${infer Param},${infer Rest}`
        ? CIsHiddenParam<Policy, CParamName<Param>> extends true
          ? CParamTuple<Decls, Policy, Rest>
          : [CParamValueType<Decls, Policy, Param>, ...CParamTuple<Decls, Policy, Rest>]
        : CIsHiddenParam<Policy, CParamName<Params>> extends true
          ? []
          : [CParamValueType<Decls, Policy, Params>];

  type CInferOutReturn<
    Decls extends string,
    Name extends string,
    OutName extends string,
  > =
    [CFindOutParamNamedType<CFunctionParamsForName<Decls, Name>, OutName>] extends [never]
      ? any
      : CFindOutParamNamedType<CFunctionParamsForName<Decls, Name>, OutName> extends infer TypeName extends string
        ? TypeName extends COpaqueHandleNames<Decls>
          ? CHandle<TypeName>
          : any
        : any;

  type CReturnPolicyResult<
    Decls extends string,
    Name extends string,
    Policy extends CFunctionReturnPolicy | undefined,
  > =
    Policy extends { kind: "handle"; type: infer TypeName extends string }
      ? CHandle<TypeName> | 0
      : Policy extends { out: infer OutName extends string }
        ? CInferOutReturn<Decls, Name, OutName>
        : CDirectReturnFromChunk<Decls, CReturnChunkFromStatement<CFindFunctionStatement<Decls, Name>, Name>>;

  type CFunctionResult<
    Decls extends string,
    Opts extends CDeclOptions | undefined,
    Name extends string,
  > =
    Opts extends { functions: infer Functions extends Record<string, CFunctionPolicy> }
      ? Name extends keyof Functions
        ? CReturnPolicyResult<Decls, Name, Functions[Name]["returns"]>
        : CDirectReturnFromChunk<Decls, CReturnChunkFromStatement<CFindFunctionStatement<Decls, Name>, Name>>
      : CDirectReturnFromChunk<Decls, CReturnChunkFromStatement<CFindFunctionStatement<Decls, Name>, Name>>;

  type CFunctionArgs<
    Decls extends string,
    Opts extends CDeclOptions | undefined,
    Name extends string,
  > = CParamTuple<
    Decls,
    CFunctionPolicyFor<Opts, Name>,
    CFunctionParamsForName<Decls, Name>
  >;

  type CBoundLibrary<
    Decls extends string = string,
    Opts extends CDeclOptions | undefined = CDeclOptions | undefined,
  > = {
    [Name in CFunctionNames<Decls>]: (...args: CFunctionArgs<Decls, Opts, Name>) => CFunctionResult<Decls, Opts, Name>
  } & {
    close(): void;
  };

  /**
   * Bind a constrained C ABI surface from C-like declarations.
   *
   * This higher-level layer sits on top of raw `std:ffi` calls and is intended for
   * wrapper authors. The supported declaration grammar is intentionally narrow.
   */
  function cdecl<
    const Decls extends string,
  >(
    name: string,
    declarations: Decls,
  ): CBoundLibrary<Decls, undefined>;

  function cdecl<
    const Decls extends string,
    const Opts,
  >(
    name: string,
    declarations: Decls,
    opts: Opts extends CDeclOptions ? Opts : CDeclOptions,
  ): CBoundLibrary<Decls, Opts extends CDeclOptions ? Opts : undefined>;

  const c: {
    decl: typeof cdecl;
  };

  const ffiModule: {
    dlopen: typeof dlopen;
    c: typeof c;
  };

  export {
    dlopen,
    c,
    Pointer,
    FFIType,
    type CBoundLibrary,
    type CDeclOptions,
    type CBufferPolicy,
    type CFunctionErrorPolicy,
    type CFunctionPolicy,
    type CFunctionReturnPolicy,
    type CHandle,
    type CHandlePolicy,
    type CMessageFunctionSource,
    type CSearchOptions,
  };

  export default ffiModule;
}
