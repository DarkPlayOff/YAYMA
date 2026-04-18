use std::fs;

fn main() {
    let pubspec_path = "frontend/pubspec.yaml";
    
    if let Ok(content) = fs::read_to_string(pubspec_path) {
        for line in content.lines() {
            if line.trim().starts_with("version:") {
                let version = line.split(':').nth(1).unwrap_or("0.0.0").trim();
                let version_only = version.split('+').next().unwrap_or(version);
                
                println!("cargo:rustc-env=PUBSPEC_VERSION={}", version_only);
                break;
            }
        }
    } else {
        println!("cargo:rustc-env=PUBSPEC_VERSION=0.0.0");
    }
    println!("cargo:rerun-if-changed=frontend/pubspec.yaml");
    println!("cargo:rerun-if-changed=build.rs");
}
