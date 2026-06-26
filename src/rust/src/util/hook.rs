pub fn set_panic_hook() {
    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |panic_info| {
        tracing::error!(panic = %panic_info, "application panic occurred");
        hook(panic_info);
    }));
}
