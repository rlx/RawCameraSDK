//! Compiles the portable core (LibRaw and the C interface) into this crate.
//!
//! The file list and definitions must stay in step with Package.swift and CMakeLists.txt.

use std::path::{Path, PathBuf};

fn collect(dir: &Path, sources: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).expect("LibRaw sources; is the submodule checked out?") {
        let path = entry.unwrap().path();
        if path.is_dir() {
            collect(&path, sources);
        } else if path.extension().is_some_and(|e| e == "cpp") {
            // Stand-ins LibRaw compiles only when the real stage is left out of a build.
            if !path.file_name().unwrap().to_string_lossy().ends_with("_ph.cpp") {
                sources.push(path);
            }
        }
    }
}

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let libraw = root.join("Vendor/LibRaw");
    let shim = root.join("Sources/RawShim");

    let mut sources = Vec::new();
    collect(&libraw.join("src"), &mut sources);
    sources.push(shim.join("RawShim.cpp"));

    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .warnings(false) // LibRaw's warnings
        .define("USE_ZLIB", None)
        .define("USE_X3FTOOLS", None)
        .include(&libraw)
        .include(shim.join("include"))
        .files(&sources)
        .compile("rawinput_core");

    println!("cargo:rustc-link-lib=z");
    println!("cargo:rerun-if-changed={}", shim.display());
    println!("cargo:rerun-if-changed={}", libraw.join("src").display());
}
