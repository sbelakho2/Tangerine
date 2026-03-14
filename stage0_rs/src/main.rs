#![deny(clippy::all, clippy::pedantic, warnings)]

use std::env;
use std::path::Path;

use stage0_rs::driver::{
    analyze_directory, analyze_module_from_path, codegen_directory, codegen_module_from_path, parse_module_from_path,
};

fn main() {
    let mut args = env::args().skip(1);
    match (args.next().as_deref(), args.next()) {
        (Some("parse"), Some(path)) => match parse_module_from_path(Path::new(&path)) {
            Ok(module) => {
                println!("ok: decls={}", module.decls.len());
            }
            Err(error) => {
                eprintln!("error: {error}");
                std::process::exit(1);
            }
        },
        (Some("analyze"), Some(path)) => match analyze_module_from_path(Path::new(&path)) {
            Ok((module, env)) => {
                println!(
                    "ok: decls={}, structs={}, traits={}, functions={}",
                    module.decls.len(),
                    env.structs.len(),
                    env.traits.len(),
                    env.functions.len()
                );
            }
            Err(error) => {
                eprintln!("error: {error}");
                std::process::exit(1);
            }
        },
        (Some("scan"), Some(path)) => match analyze_directory(Path::new(&path)) {
            Ok(results) => {
                let supported = results.iter().filter(|(_, result)| result.is_ok()).count();
                let unsupported = results.len().saturating_sub(supported);
                println!("supported={supported} unsupported={unsupported}");
                for (path, result) in results {
                    if let Err(error) = result {
                        println!("FAIL {} :: {}", path.display(), error);
                    }
                }
            }
            Err(error) => {
                eprintln!("error: {error}");
                std::process::exit(1);
            }
        },
        (Some("codegen"), Some(path)) => match codegen_module_from_path(Path::new(&path)) {
            Ok(()) => {
                println!("ok: codegen validated");
            }
            Err(error) => {
                eprintln!("error: {error}");
                std::process::exit(1);
            }
        },
        (Some("codegen-scan"), Some(path)) => match codegen_directory(Path::new(&path)) {
            Ok(results) => {
                let supported = results.iter().filter(|(_, result)| result.is_ok()).count();
                let unsupported = results.len().saturating_sub(supported);
                println!("supported={supported} unsupported={unsupported}");
                for (path, result) in results {
                    if let Err(error) = result {
                        println!("FAIL {} :: {}", path.display(), error);
                    }
                }
            }
            Err(error) => {
                eprintln!("error: {error}");
                std::process::exit(1);
            }
        },
        _ => {
            println!("usage: stage0_rs parse <file.tg> | analyze <file.tg> | scan <directory> | codegen <file.tg> | codegen-scan <directory>");
        }
    }
}
