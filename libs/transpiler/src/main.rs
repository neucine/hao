use oxc_allocator::Allocator;
use oxc_codegen::Codegen;
use oxc_parser::Parser;
use oxc_semantic::SemanticBuilder;
use oxc_span::SourceType;
use oxc_transformer::{TransformOptions, Transformer};
use std::fs;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: transpiler <input.ts> <output.js>");
        std::process::exit(1);
    }

    let source = fs::read_to_string(&args[1]).expect("Failed to read input file");

    let allocator = Allocator::default();
    let source_type = SourceType::ts();
    let ret = Parser::new(&allocator, &source, source_type).parse();
    if !ret.errors.is_empty() {
        eprintln!("Parse errors:");
        for err in &ret.errors {
            eprintln!("  {}", err);
        }
        std::process::exit(1);
    }

    let mut program = ret.program;
    let semantic_ret = SemanticBuilder::new().build(&program);
    let scoping = semantic_ret.semantic.into_scoping();

    let transform_options = TransformOptions::default();
    let _ = Transformer::new(
        &allocator,
        std::path::Path::new(&args[1]),
        &transform_options,
    )
    .build_with_scoping(scoping, &mut program);

    let output = Codegen::new().build(&program).code;
    fs::write(&args[2], output).expect("Failed to write output file");
}
