#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

pub mod api;
pub use crate::api::simple::*;
pub mod app;
pub mod audio;
pub mod auth;
pub mod storage;
pub mod db {
    pub use crate::storage::db::*;
}
mod frb_generated;
pub mod http;
pub mod stream;
pub mod util;

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "C" fn Java_io_github_darkplayoff_yayma_MainActivity_initRustls(
    mut env: jni::JNIEnv,
    _class: jni::objects::JClass,
    context: jni::objects::JObject,
) {
    // Initialize ndk-context for CPAL (audio playback)
    static INIT_NDK: std::sync::Once = std::sync::Once::new();
    INIT_NDK.call_once(|| {
        unsafe {
            let vm = env.get_java_vm().expect("Failed to get JavaVM");
            let context_global = env.new_global_ref(&context).expect("Failed to create GlobalRef");
            let context_raw = context_global.as_obj().as_raw();
            
            ndk_context::initialize_android_context(
                vm.get_java_vm_pointer() as *mut std::ffi::c_void,
                context_raw as *mut std::ffi::c_void,
            );
            
            // Leak the global reference so it stays alive for the duration of the app
            std::mem::forget(context_global);
        }
    });
    
    rustls_platform_verifier::android::init_hosted(&mut env, context)
        .expect("Failed to initialize rustls-platform-verifier");
}
