use oxc_allocator::Allocator;
use oxc_ast::ast::{
    BindingPattern, Declaration, ExportDefaultDeclarationKind, ImportDeclarationSpecifier,
    ModuleExportName, Statement,
};
use oxc_codegen::Codegen;
use oxc_codegen::CodegenOptions;
use oxc_parser::Parser;
use oxc_semantic::SemanticBuilder;
use oxc_span::SourceType;
use oxc_transformer::{TransformOptions, Transformer};
use serde::Serialize;
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

type SourceMapStore = HashMap<String, oxc_sourcemap::SourceMap>;
type RewriteMapStore = HashMap<String, Vec<u32>>;

static SOURCE_MAPS: OnceLock<Mutex<SourceMapStore>> = OnceLock::new();
static REWRITE_LINE_MAPS: OnceLock<Mutex<RewriteMapStore>> = OnceLock::new();
static LAST_ERROR: OnceLock<Mutex<Option<String>>> = OnceLock::new();

#[derive(Serialize)]
struct ModuleManifest {
    imports: Vec<ImportRecord>,
    export_decls: Vec<ExportDeclRecord>,
    reexports: Vec<ReexportRecord>,
}

#[derive(Serialize)]
struct ImportRecord {
    span_start: usize,
    span_end: usize,
    source: String,
    kind: String,
    imported: Option<String>,
    local: String,
}

#[derive(Serialize)]
struct ExportDeclRecord {
    span_start: usize,
    span_end: usize,
    kind: String,
    bindings: Vec<ExportBindingRecord>,
}

#[derive(Serialize)]
struct ExportBindingRecord {
    export_name: String,
    local_name: String,
}

#[derive(Serialize)]
struct ReexportRecord {
    span_start: usize,
    span_end: usize,
    source: String,
    kind: String,
    imported: Option<String>,
    exported: Option<String>,
}

#[derive(Serialize)]
struct TransformModuleResult {
    code: String,
    source_url: String,
    imports: Vec<TransformImportRecord>,
    exports_slot: String,
}

#[derive(Serialize)]
struct TransformEsmModuleResult {
    code: String,
    source_url: String,
}

#[derive(Serialize)]
struct TransformImportRecord {
    slot: String,
    source: String,
}

#[derive(Clone)]
struct TransformImportSlot {
    span_start: usize,
    span_end: usize,
    source: String,
    slot: String,
    param: String,
}

struct RewriteResult {
    code: String,
    line_map: Vec<u32>,
}

/// Strip TypeScript types from source.
/// Returns a heap-allocated C string. Caller must call hao_transpiler_free() on the result.
/// Returns null on error.
#[no_mangle]
pub extern "C" fn hao_transpile_types(source: *const c_char) -> *mut c_char {
    hao_transpile_types_for_path(source, std::ptr::null())
}

#[derive(Serialize)]
struct OriginalPosition {
    source: String,
    line: u32,
    column: u32,
}

#[no_mangle]
pub extern "C" fn hao_transpile_types_for_path(
    source: *const c_char,
    source_path: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let source = unsafe {
        if source.is_null() {
            set_last_error("Transpile failed: missing source".to_string());
            return std::ptr::null_mut();
        }
        match CStr::from_ptr(source).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                set_last_error("Transpile failed: source is not valid UTF-8".to_string());
                return std::ptr::null_mut();
            }
        }
    };
    let parsed_source_path = parse_optional_cstr(source_path);

    let allocator = Allocator::default();
    let source_type = SourceType::ts();
    let ret = Parser::new(&allocator, &source, source_type).parse();
    if !ret.errors.is_empty() {
        set_last_error(format_parse_error(
            &source,
            parsed_source_path.as_deref().unwrap_or("input.ts"),
            &ret.errors[0],
        ));
        return std::ptr::null_mut();
    }

    let mut program = ret.program;

    // Build semantic analysis to get Scoping (required by Transformer)
    let semantic_ret = SemanticBuilder::new().build(&program);
    let scoping = semantic_ret.semantic.into_scoping();

    let transform_options = TransformOptions::default();
    let transpile_path = parsed_source_path.as_deref().unwrap_or("input.ts");
    let _ = Transformer::new(&allocator, Path::new(transpile_path), &transform_options)
        .build_with_scoping(scoping, &mut program);

    let mut codegen_options = CodegenOptions::default();
    if !source_path.is_null() {
        codegen_options.source_map_path = Some(Path::new(transpile_path).to_path_buf());
    }
    let generated = Codegen::new().with_options(codegen_options).build(&program);
    if let Some(map) = generated.map {
        if let Some(path) = parsed_source_path {
            let store = SOURCE_MAPS.get_or_init(|| Mutex::new(HashMap::new()));
            if let Ok(mut maps) = store.lock() {
                maps.insert(path, map);
            }
        }
    }
    let output = generated.code;
    match CString::new(output) {
        Ok(s) => s.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn hao_lookup_original_position(
    source_path: *const c_char,
    generated_line: u32,
    generated_column: u32,
) -> *mut c_char {
    let Some(path) = parse_optional_cstr(source_path) else {
        return std::ptr::null_mut();
    };
    let rewrite_line = lookup_rewrite_line(&path, generated_line).unwrap_or(generated_line);

    let original = if let Some(store) = SOURCE_MAPS.get() {
        let Ok(maps) = store.lock() else {
            return std::ptr::null_mut();
        };
        if let Some(map) = maps.get(&path) {
            let lookup = map.generate_lookup_table();
            let line = generated_line.saturating_sub(1);
            let column = generated_column.saturating_sub(1);
            if let Some(token) = map.lookup_source_view_token(&lookup, line, column) {
                let source = token
                    .get_source()
                    .map(|src| src.to_string())
                    .unwrap_or_else(|| path.clone());
                let transpiled_line = token.get_src_line() + 1;
                OriginalPosition {
                    source,
                    line: lookup_rewrite_line(&path, transpiled_line).unwrap_or(transpiled_line),
                    column: token.get_src_col() + 1,
                }
            } else {
                OriginalPosition {
                    source: path.clone(),
                    line: rewrite_line,
                    column: generated_column,
                }
            }
        } else {
            OriginalPosition {
                source: path.clone(),
                line: rewrite_line,
                column: generated_column,
            }
        }
    } else {
        OriginalPosition {
            source: path.clone(),
            line: rewrite_line,
            column: generated_column,
        }
    };

    match serde_json::to_string(&original)
        .ok()
        .and_then(|json| CString::new(json).ok())
    {
        Some(s) => s.into_raw(),
        None => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn hao_transform_module(
    source: *const c_char,
    source_path: *const c_char,
    isolated: u8,
    namespace_root: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let source = unsafe {
        if source.is_null() {
            set_last_error("Transpile failed: missing source".to_string());
            return std::ptr::null_mut();
        }
        match CStr::from_ptr(source).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                set_last_error("Transpile failed: source is not valid UTF-8".to_string());
                return std::ptr::null_mut();
            }
        }
    };
    let source_path = parse_optional_cstr(source_path).unwrap_or_else(|| "input.ts".to_string());
    let namespace_root = parse_optional_cstr(namespace_root)
        .unwrap_or_else(|| "__hao_runtime_modules".to_string());

    let allocator = Allocator::default();
    let source_type = SourceType::ts();
    let ret = Parser::new(&allocator, &source, source_type).parse();
    if !ret.errors.is_empty() {
        set_last_error(format_parse_error(&source, &source_path, &ret.errors[0]));
        return std::ptr::null_mut();
    }

    let manifest = scan_manifest_from_program(&ret.program);
    let import_slots = build_transform_import_slots(&manifest, &source_path);
    let exports_slot = format!("__hao_exports_{:x}", simple_hash(&source_path));
    let rewritten = rewrite_module(
        &source,
        &manifest,
        &import_slots,
        &exports_slot,
        isolated != 0,
        &namespace_root,
    );
    register_rewrite_line_map(&source_path, rewritten.line_map.clone());

    let code = if source_path.ends_with(".ts") || source_path.ends_with(".tsx") {
        let source_c = match CString::new(rewritten.code.as_str()) {
            Ok(value) => value,
            Err(_) => return std::ptr::null_mut(),
        };
        let source_path_c = match CString::new(source_path.as_str()) {
            Ok(value) => value,
            Err(_) => return std::ptr::null_mut(),
        };
        let stripped = hao_transpile_types_for_path(source_c.as_ptr(), source_path_c.as_ptr());
        if stripped.is_null() {
            return std::ptr::null_mut();
        }
        let result = unsafe { CStr::from_ptr(stripped).to_string_lossy().to_string() };
        hao_transpiler_free(stripped);
        result
    } else {
        rewritten.code
    };

    let transformed = TransformModuleResult {
        code,
        source_url: source_path.clone(),
        imports: import_slots
            .into_iter()
            .map(|record| TransformImportRecord {
                slot: record.slot,
                source: record.source,
            })
            .collect(),
        exports_slot,
    };

    match serde_json::to_string(&transformed)
        .ok()
        .and_then(|json| CString::new(json).ok())
    {
        Some(s) => s.into_raw(),
        None => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn hao_transform_esm_module(
    source: *const c_char,
    source_path: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let source_url = parse_optional_cstr(source_path).unwrap_or_else(|| "input.ts".to_string());
    let stripped = hao_transpile_types_for_path(source, source_path);
    if stripped.is_null() {
        return std::ptr::null_mut();
    }
    let code = unsafe { CStr::from_ptr(stripped).to_string_lossy().to_string() };
    hao_transpiler_free(stripped);

    let transformed = TransformEsmModuleResult { code, source_url };
    match serde_json::to_string(&transformed)
        .ok()
        .and_then(|json| CString::new(json).ok())
    {
        Some(s) => s.into_raw(),
        None => std::ptr::null_mut(),
    }
}

fn scan_manifest_from_program(program: &oxc_ast::ast::Program<'_>) -> ModuleManifest {
    let mut manifest = ModuleManifest {
        imports: Vec::new(),
        export_decls: Vec::new(),
        reexports: Vec::new(),
    };

    for stmt in &program.body {
        match stmt {
            Statement::ImportDeclaration(decl) => {
                let source = decl.source.value.as_str().to_string();
                match &decl.specifiers {
                    None => {
                        manifest.imports.push(ImportRecord {
                            span_start: decl.span.start as usize,
                            span_end: decl.span.end as usize,
                            source,
                            kind: "side_effect".to_string(),
                            imported: None,
                            local: "".to_string(),
                        });
                    }
                    Some(specifiers) => {
                        for spec in specifiers {
                            match spec {
                                ImportDeclarationSpecifier::ImportSpecifier(spec) => {
                                    manifest.imports.push(ImportRecord {
                                        span_start: decl.span.start as usize,
                                        span_end: decl.span.end as usize,
                                        source: source.clone(),
                                        kind: "named".to_string(),
                                        imported: Some(module_export_name(&spec.imported)),
                                        local: spec.local.name.as_str().to_string(),
                                    });
                                }
                                ImportDeclarationSpecifier::ImportDefaultSpecifier(spec) => {
                                    manifest.imports.push(ImportRecord {
                                        span_start: decl.span.start as usize,
                                        span_end: decl.span.end as usize,
                                        source: source.clone(),
                                        kind: "default".to_string(),
                                        imported: Some("default".to_string()),
                                        local: spec.local.name.as_str().to_string(),
                                    });
                                }
                                ImportDeclarationSpecifier::ImportNamespaceSpecifier(spec) => {
                                    manifest.imports.push(ImportRecord {
                                        span_start: decl.span.start as usize,
                                        span_end: decl.span.end as usize,
                                        source: source.clone(),
                                        kind: "namespace".to_string(),
                                        imported: Some("*".to_string()),
                                        local: spec.local.name.as_str().to_string(),
                                    });
                                }
                            }
                        }
                    }
                }
            }
            Statement::ExportNamedDeclaration(decl) => {
                if let Some(source) = &decl.source {
                    let source = source.value.as_str().to_string();
                    for spec in &decl.specifiers {
                        manifest.reexports.push(ReexportRecord {
                            span_start: decl.span.start as usize,
                            span_end: decl.span.end as usize,
                            source: source.clone(),
                            kind: "named".to_string(),
                            imported: Some(module_export_name(&spec.local)),
                            exported: Some(module_export_name(&spec.exported)),
                        });
                    }
                } else if decl.declaration.is_some() {
                    let bindings = collect_declaration_bindings(decl.declaration.as_ref().unwrap());
                    manifest.export_decls.push(ExportDeclRecord {
                        span_start: decl.span.start as usize,
                        span_end: decl.span.end as usize,
                        kind: "named_declaration".to_string(),
                        bindings,
                    });
                } else {
                    manifest.export_decls.push(ExportDeclRecord {
                        span_start: decl.span.start as usize,
                        span_end: decl.span.end as usize,
                        kind: "named_list".to_string(),
                        bindings: decl
                            .specifiers
                            .iter()
                            .map(|spec| ExportBindingRecord {
                                export_name: module_export_name(&spec.exported),
                                local_name: module_export_name(&spec.local),
                            })
                            .collect(),
                    });
                }
            }
            Statement::ExportDefaultDeclaration(decl) => {
                let kind = match &decl.declaration {
                    ExportDefaultDeclarationKind::FunctionDeclaration(_) => "default_function",
                    ExportDefaultDeclarationKind::ClassDeclaration(_) => "default_class",
                    ExportDefaultDeclarationKind::TSInterfaceDeclaration(_) => {
                        "default_ts_interface"
                    }
                    _ => "default_expression",
                };
                manifest.export_decls.push(ExportDeclRecord {
                    span_start: decl.span.start as usize,
                    span_end: decl.span.end as usize,
                    kind: kind.to_string(),
                    bindings: Vec::new(),
                });
            }
            Statement::ExportAllDeclaration(decl) => {
                manifest.reexports.push(ReexportRecord {
                    span_start: decl.span.start as usize,
                    span_end: decl.span.end as usize,
                    source: decl.source.value.as_str().to_string(),
                    kind: if decl.exported.is_some() {
                        "all_as".to_string()
                    } else {
                        "all".to_string()
                    },
                    imported: Some("*".to_string()),
                    exported: decl.exported.as_ref().map(module_export_name),
                });
            }
            _ => {}
        }
    }

    manifest
}

fn build_transform_import_slots(
    manifest: &ModuleManifest,
    source_path: &str,
) -> Vec<TransformImportSlot> {
    let mut out = Vec::new();
    let mut import_index = 0usize;
    let slot_prefix = format!("__hao_imp_{:x}", simple_hash(source_path));

    let mut current_span: Option<(usize, usize)> = None;
    for record in &manifest.imports {
        let span = (record.span_start, record.span_end);
        if current_span != Some(span) {
            out.push(TransformImportSlot {
                span_start: record.span_start,
                span_end: record.span_end,
                source: record.source.clone(),
                slot: format!("{slot_prefix}_{import_index}"),
                param: format!("__hao_mod_{import_index}"),
            });
            current_span = Some(span);
            import_index += 1;
        }
    }

    for record in &manifest.reexports {
        out.push(TransformImportSlot {
            span_start: record.span_start,
            span_end: record.span_end,
            source: record.source.clone(),
            slot: format!("{slot_prefix}_{import_index}"),
            param: format!("__hao_mod_{import_index}"),
        });
        import_index += 1;
    }

    out
}

fn rewrite_module(
    source: &str,
    manifest: &ModuleManifest,
    import_slots: &[TransformImportSlot],
    exports_slot: &str,
    isolated: bool,
    namespace_root: &str,
) -> RewriteResult {
    let namespaced_ref = |slot: &str| format!("{namespace_root}[\"{slot}\"]");
    let body_exports_ref = if isolated {
        "__hao_module".to_string()
    } else {
        namespaced_ref(exports_slot)
    };
    let mut body = RewriteBuilder::new(source);
    let mut cursor = 0usize;
    let mut import_index = 0usize;
    let mut export_index = 0usize;
    let mut reexport_index = 0usize;

    while import_index < manifest.imports.len()
        || export_index < manifest.export_decls.len()
        || reexport_index < manifest.reexports.len()
    {
        let next_import = manifest
            .imports
            .get(import_index)
            .map(|record| record.span_start);
        let next_export = manifest
            .export_decls
            .get(export_index)
            .map(|record| record.span_start);
        let next_reexport = manifest
            .reexports
            .get(reexport_index)
            .map(|record| record.span_start);

        let next_kind = [
            next_import.map(|span| ("import", span)),
            next_export.map(|span| ("export", span)),
            next_reexport.map(|span| ("reexport", span)),
        ]
        .into_iter()
        .flatten()
        .min_by_key(|(_, span)| *span);

        let Some((kind, start)) = next_kind else {
            break;
        };

        if start > cursor {
            body.append_original_slice(&source[cursor..start], cursor);
        }

        match kind {
            "import" => {
                let record = &manifest.imports[import_index];
                let decl_start = record.span_start;
                let decl_end = record.span_end;
                let slot = import_slots
                    .iter()
                    .find(|entry| entry.span_start == decl_start && entry.span_end == decl_end)
                    .map(|entry| if isolated { entry.param.as_str() } else { "" })
                    .unwrap_or("__hao_imp_missing");
                let slot_ref = if isolated {
                    slot.to_string()
                } else {
                    namespaced_ref(
                        &import_slots
                            .iter()
                            .find(|entry| {
                                entry.span_start == decl_start && entry.span_end == decl_end
                            })
                            .map(|entry| entry.slot.clone())
                            .unwrap_or_else(|| "__hao_imp_missing".to_string()),
                    )
                };
                while import_index < manifest.imports.len()
                    && manifest.imports[import_index].span_start == decl_start
                    && manifest.imports[import_index].span_end == decl_end
                {
                    let import_record = &manifest.imports[import_index];
                    match import_record.kind.as_str() {
                        "named" => {
                            body.append_generated_text(
                                &format!(
                                    "const {} = {}.{};",
                                    import_record.local,
                                    &slot_ref,
                                    import_record.imported.as_deref().unwrap_or("")
                                ),
                                decl_start,
                            );
                        }
                        "default" => {
                            body.append_generated_text(
                                &format!(
                                    "const {} = {}.default ?? {};",
                                    import_record.local, &slot_ref, &slot_ref
                                ),
                                decl_start,
                            );
                        }
                        "namespace" => {
                            body.append_generated_text(
                                &format!("const {} = {};", import_record.local, &slot_ref),
                                decl_start,
                            );
                        }
                        "side_effect" => {}
                        _ => {}
                    }
                    import_index += 1;
                }
                cursor = decl_end;
            }
            "export" => {
                let decl = &manifest.export_decls[export_index];
                let exported_slice = &source[decl.span_start..decl.span_end];
                if decl.kind == "named_declaration" {
                    let prefix = "export ";
                    if exported_slice.starts_with(prefix) {
                        body.append_original_slice(
                            &exported_slice[prefix.len()..],
                            decl.span_start + prefix.len(),
                        );
                    } else {
                        body.append_original_slice(exported_slice, decl.span_start);
                    }
                    for binding in &decl.bindings {
                        body.append_generated_text(
                            &format!(
                                "\n{}.{} = {};",
                                &body_exports_ref, binding.export_name, binding.local_name
                            ),
                            decl.span_start,
                        );
                    }
                } else if decl.kind.starts_with("default_") {
                    let prefix = "export default ";
                    let after_default = exported_slice
                        .strip_prefix(prefix)
                        .unwrap_or(exported_slice);
                    body.append_generated_text("const __hao_default = ", decl.span_start);
                    body.append_original_slice(
                        after_default,
                        decl.span_start + exported_slice.len() - after_default.len(),
                    );
                    body.append_generated_text(
                        &format!("; {}.default = __hao_default;", &body_exports_ref),
                        decl.span_start,
                    );
                } else if decl.kind == "named_list" {
                    for binding in &decl.bindings {
                        body.append_generated_text(
                            &format!(
                                "{}.{} = {};",
                                &body_exports_ref, binding.export_name, binding.local_name
                            ),
                            decl.span_start,
                        );
                    }
                }
                cursor = decl.span_end;
                export_index += 1;
            }
            "reexport" => {
                let record = &manifest.reexports[reexport_index];
                let slot = import_slots
                    .iter()
                    .find(|entry| {
                        entry.span_start == record.span_start
                            && entry.span_end == record.span_end
                            && entry.source == record.source
                    })
                    .map(|entry| if isolated { entry.param.as_str() } else { "" })
                    .unwrap_or("__hao_imp_missing");
                let slot_ref = if isolated {
                    slot.to_string()
                } else {
                    namespaced_ref(
                        &import_slots
                            .iter()
                            .find(|entry| {
                                entry.span_start == record.span_start
                                    && entry.span_end == record.span_end
                                    && entry.source == record.source
                            })
                            .map(|entry| entry.slot.clone())
                            .unwrap_or_else(|| "__hao_imp_missing".to_string()),
                    )
                };
                if record.kind == "named" {
                    body.append_generated_text(
                        &format!(
                            "{}.{} = {}.{};",
                            &body_exports_ref,
                            record.exported.as_deref().unwrap_or(""),
                            &slot_ref,
                            record.imported.as_deref().unwrap_or("")
                        ),
                        record.span_start,
                    );
                } else if record.kind == "all" {
                    body.append_generated_text(
                        &format!(
                            "for (const __k in {}) {{ if (__k !== 'default') {}[__k] = {}[__k]; }}",
                            &slot_ref, &body_exports_ref, &slot_ref
                        ),
                        record.span_start,
                    );
                } else {
                    body.append_generated_text(";", record.span_start);
                }
                cursor = record.span_end;
                reexport_index += 1;
            }
            _ => {}
        }
    }

    if cursor < source.len() {
        body.append_original_slice(&source[cursor..], cursor);
    }

    if !isolated {
        return body.finish();
    }

    let params = import_slots
        .iter()
        .map(|slot| slot.param.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    let args = import_slots
        .iter()
        .map(|slot| namespaced_ref(slot.slot.as_str()))
        .collect::<Vec<_>>()
        .join(", ");
    let separator = if params.is_empty() { "" } else { ", " };
    let last_original_line = body.last_original_line();
    let body = body.finish();
    let final_code = format!(
        "((__hao_module{separator}{params}) => {{\n{}\nreturn __hao_module;\n}})({exports_slot}{separator}{args})",
        body.code,
        exports_slot = namespaced_ref(exports_slot),
    );
    let mut line_map = Vec::with_capacity(body.line_map.len() + 3);
    line_map.push(1);
    line_map.extend(body.line_map);
    line_map.push(last_original_line);
    line_map.push(last_original_line);
    RewriteResult {
        code: final_code,
        line_map,
    }
}

/// Free a string returned by transpiler FFI helpers.
#[no_mangle]
pub extern "C" fn hao_transpiler_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

#[no_mangle]
pub extern "C" fn hao_transpiler_last_error() -> *mut c_char {
    let store = LAST_ERROR.get_or_init(|| Mutex::new(None));
    let Ok(guard) = store.lock() else {
        return std::ptr::null_mut();
    };
    let Some(message) = guard.as_ref() else {
        return std::ptr::null_mut();
    };
    match CString::new(message.as_str()) {
        Ok(s) => s.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn parse_optional_cstr(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value).to_str().ok().map(ToOwned::to_owned) }
}

fn clear_last_error() {
    let store = LAST_ERROR.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = store.lock() {
        *guard = None;
    }
}

fn set_last_error(message: String) {
    let store = LAST_ERROR.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = store.lock() {
        *guard = Some(message.replace('\0', "\\0"));
    }
}

fn format_parse_error(source: &str, source_path: &str, diagnostic: &oxc_diagnostics::OxcDiagnostic) -> String {
    let inner = diagnostic.clone().inner_owned();
    let message = inner.message.to_string();
    let labels = inner.labels.unwrap_or_default();
    let label = labels.iter().find(|label| label.primary()).or_else(|| labels.first());
    let Some(label) = label else {
        return format!("Transpile failed in {source_path}: {message}");
    };

    let offset = label.offset().min(source.len());
    let (line, column, line_text) = source_location(source, offset);
    let underline_len = label.len().max(1).min(line_text.len().saturating_sub(column.saturating_sub(1)).max(1));
    let mut caret = String::new();
    for ch in line_text.chars().take(column.saturating_sub(1)) {
        caret.push(if ch == '\t' { '\t' } else { ' ' });
    }
    caret.push('^');
    for _ in 1..underline_len {
        caret.push('~');
    }

    format!(
        "Transpile failed in {source_path}:{line}:{column}\n{message}\n\n{line_text}\n{caret}"
    )
}

fn source_location(source: &str, offset: usize) -> (usize, usize, String) {
    let mut line = 1usize;
    let mut line_start = 0usize;
    for (idx, byte) in source.bytes().enumerate() {
        if idx >= offset {
            break;
        }
        if byte == b'\n' {
            line += 1;
            line_start = idx + 1;
        }
    }

    let line_end = source[line_start..]
        .find('\n')
        .map(|rel| line_start + rel)
        .unwrap_or(source.len());
    let line_text = source[line_start..line_end].trim_end_matches('\r').to_string();
    let column = source[line_start..offset]
        .chars()
        .count()
        .saturating_add(1);
    (line, column, line_text)
}

fn simple_hash(value: &str) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    use std::hash::Hash;
    use std::hash::Hasher;
    value.hash(&mut hasher);
    hasher.finish()
}

fn module_export_name(name: &ModuleExportName<'_>) -> String {
    match name {
        ModuleExportName::IdentifierName(it) => it.name.as_str().to_string(),
        ModuleExportName::IdentifierReference(it) => it.name.as_str().to_string(),
        ModuleExportName::StringLiteral(it) => it.value.as_str().to_string(),
    }
}

fn collect_declaration_bindings(decl: &Declaration<'_>) -> Vec<ExportBindingRecord> {
    match decl {
        Declaration::FunctionDeclaration(function) => function
            .id
            .as_ref()
            .map(|id| {
                let name = id.name.as_str().to_string();
                vec![ExportBindingRecord {
                    export_name: name.clone(),
                    local_name: name,
                }]
            })
            .unwrap_or_default(),
        Declaration::ClassDeclaration(class) => class
            .id
            .as_ref()
            .map(|id| {
                let name = id.name.as_str().to_string();
                vec![ExportBindingRecord {
                    export_name: name.clone(),
                    local_name: name,
                }]
            })
            .unwrap_or_default(),
        Declaration::VariableDeclaration(var_decl) => {
            let mut bindings = Vec::new();
            for declarator in &var_decl.declarations {
                collect_binding_pattern_names(&declarator.id, &mut bindings);
            }
            bindings
        }
        _ => Vec::new(),
    }
}

fn collect_binding_pattern_names(pattern: &BindingPattern<'_>, out: &mut Vec<ExportBindingRecord>) {
    match pattern {
        BindingPattern::BindingIdentifier(id) => {
            let name = id.name.as_str().to_string();
            out.push(ExportBindingRecord {
                export_name: name.clone(),
                local_name: name,
            });
        }
        BindingPattern::AssignmentPattern(assign) => {
            collect_binding_pattern_names(&assign.left, out);
        }
        _ => {}
    }
}

struct RewriteBuilder<'a> {
    line_starts: Vec<usize>,
    code: String,
    line_map: Vec<u32>,
    _marker: std::marker::PhantomData<&'a str>,
}

impl<'a> RewriteBuilder<'a> {
    fn new(source: &'a str) -> Self {
        Self {
            line_starts: build_line_starts(source),
            code: String::new(),
            line_map: Vec::new(),
            _marker: std::marker::PhantomData,
        }
    }

    fn append_original_slice(&mut self, text: &str, source_offset: usize) {
        if text.is_empty() {
            return;
        }
        let start_line = offset_to_line(&self.line_starts, source_offset);
        self.code.push_str(text);
        extend_line_map_sequential(&mut self.line_map, text, start_line);
    }

    fn append_generated_text(&mut self, text: &str, source_offset: usize) {
        if text.is_empty() {
            return;
        }
        let line = offset_to_line(&self.line_starts, source_offset);
        self.code.push_str(text);
        extend_line_map_constant(&mut self.line_map, text, line);
    }

    fn last_original_line(&self) -> u32 {
        self.line_starts.len() as u32
    }

    fn finish(self) -> RewriteResult {
        RewriteResult {
            code: self.code,
            line_map: if self.line_map.is_empty() {
                vec![1]
            } else {
                self.line_map
            },
        }
    }
}

fn build_line_starts(source: &str) -> Vec<usize> {
    let mut starts = vec![0];
    for (idx, ch) in source.char_indices() {
        if ch == '\n' && idx + 1 < source.len() {
            starts.push(idx + 1);
        }
    }
    starts
}

fn offset_to_line(line_starts: &[usize], offset: usize) -> u32 {
    match line_starts.binary_search(&offset) {
        Ok(index) => index as u32 + 1,
        Err(index) => index as u32,
    }
}

fn extend_line_map_sequential(line_map: &mut Vec<u32>, text: &str, start_line: u32) {
    let line_count = count_lines(text);
    if line_count == 0 {
        return;
    }
    if line_map.is_empty() {
        line_map.push(start_line);
    }
    for index in 1..line_count {
        line_map.push(start_line + index as u32);
    }
}

fn extend_line_map_constant(line_map: &mut Vec<u32>, text: &str, line: u32) {
    let line_count = count_lines(text);
    if line_count == 0 {
        return;
    }
    if line_map.is_empty() {
        line_map.push(line);
    }
    for _ in 1..line_count {
        line_map.push(line);
    }
}

fn count_lines(text: &str) -> usize {
    if text.is_empty() {
        return 0;
    }
    1 + text.bytes().filter(|byte| *byte == b'\n').count()
}

fn register_rewrite_line_map(path: &str, line_map: Vec<u32>) {
    let store = REWRITE_LINE_MAPS.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut maps) = store.lock() {
        maps.insert(path.to_string(), line_map);
    }
}

fn lookup_rewrite_line(path: &str, line: u32) -> Option<u32> {
    let store = REWRITE_LINE_MAPS.get()?;
    let maps = store.lock().ok()?;
    let line_map = maps.get(path)?;
    if line == 0 {
        return None;
    }
    line_map.get(line.saturating_sub(1) as usize).copied()
}
