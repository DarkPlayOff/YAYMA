use crate::api::models::{AppError, SavedStateDto, UserAccountDto};
use crate::app::{APP_DB, AppContext, initialize_app};
use crate::auth::TokenProvider;
use crate::http::ApiService;

const OAUTH_START_URL: &str = "https://passport.yandex.ru/pwl-yandex/auth/";
const OAUTH_URL: &str = "https://oauth.yandex.ru/authorize?response_type=token&client_id=97fe03033fa34407ac9bcf91d5afed5b";

pub async fn restore_saved_state(_ctx: &AppContext) -> Option<SavedStateDto> {
    let db = APP_DB.get()?.lock();
    db.load_playback_state()
        .ok()
        .flatten()
        .map(|(id, pos, playing)| SavedStateDto {
            track_id: id,
            position_ms: pos as u32,
            is_playing: playing,
        })
}

pub async fn clear_token() {
    let _ = TokenProvider::delete();
}

pub async fn login_with_token(token: String) -> Result<AppContext, AppError> {
    let (client, user_id) = TokenProvider::validate(&token)
        .await
        .map_err(|_| AppError::InvalidToken)?;

    let _ = TokenProvider::store(&token, user_id);

    let api = ApiService::new(token, Some(client), Some(user_id))
        .await
        .map_err(|e| AppError::ApiError(e.to_string()))?;

    initialize_app(api)
        .await
        .map_err(|e| AppError::Unknown(e.to_string()))
}

pub async fn try_auto_login() -> Option<AppContext> {
    let (token, _) = TokenProvider::resolve()?;
    login_with_token(token).await.ok()
}

pub async fn get_account_info(ctx: &AppContext) -> Option<UserAccountDto> {
    ctx.api.get_account_info().await.ok()
}

/// Открывает нативное окно с браузером для авторизации в Яндекс.
/// Возвращает токен или ошибку.
pub async fn login_via_webview() -> Result<String, AppError> {
    let (tx, rx) = tokio::sync::oneshot::channel::<Result<String, AppError>>();

    std::thread::spawn(move || {
        use tao::{
            event::{Event, WindowEvent},
            event_loop::{ControlFlow, EventLoopBuilder},
            window::WindowBuilder,
        };
        use wry::WebViewBuilder;
        
        // На Windows и Linux нужно явно разрешить создание EventLoop не в главном потоке.
        #[cfg(target_os = "windows")]
        use tao::platform::windows::EventLoopBuilderExtWindows;
        #[cfg(target_os = "linux")]
        use tao::platform::unix::EventLoopBuilderExtUnix;
        #[cfg(any(target_os = "windows", target_os = "linux"))]
        use tao::platform::run_return::EventLoopExtRunReturn;

        #[derive(Debug)]
        enum UserEvent {
            Redirect(String),
            Token(String),
        }

        let mut builder = EventLoopBuilder::<UserEvent>::with_user_event();
        
        #[cfg(any(target_os = "windows", target_os = "linux"))]
        builder.with_any_thread(true);

        let mut event_loop = builder.build();
        let proxy = event_loop.create_proxy();
        let proxy_nav = proxy.clone();
        
        let window = WindowBuilder::new()
            .with_title("Yandex Music Login")
            .with_inner_size(tao::dpi::LogicalSize::new(1000.0, 800.0))
            .build(&event_loop)
            .unwrap();

        let tx_opt = std::sync::Arc::new(parking_lot::Mutex::new(Some(tx)));
        let proxy_ipc = proxy.clone();

        let webview = WebViewBuilder::new()
            .with_user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
            .with_url(OAUTH_START_URL)
            .with_devtools(true)
            .with_ipc_handler(move |msg| {
                if let Some(token_part) = msg.body().strip_prefix("token:") {
                    if let Some(pos) = token_part.find("access_token=") {
                        let part = &token_part[pos + 13..];
                        let end = part.find('&').unwrap_or(part.len());
                        let token = part[..end].to_string();
                        if token.starts_with("y0_") {
                            let _ = proxy_ipc.send_event(UserEvent::Token(token));
                        }
                    }
                }
            })
            .with_initialization_script(r#"
                function checkToken() {
                    if (window.location.hash.includes('access_token=')) {
                        window.ipc.postMessage('token:' + window.location.hash);
                    }
                }
                window.addEventListener('hashchange', checkToken);
                window.addEventListener('load', checkToken);
                setInterval(checkToken, 500); 
            "#)
            .with_navigation_handler(move |url| {
                let url_str = url.as_str();

                // Мгновенный редирект при входе в профиль
                if url_str.starts_with("https://id.yandex.ru") || url_str.starts_with("https://passport.yandex.ru/profile") {
                    let _ = proxy_nav.send_event(UserEvent::Redirect(OAUTH_URL.to_string()));
                    return false;
                }

                true
            })
            .build(&window)
            .unwrap();

        let tx_opt_loop = tx_opt.clone();

        let event_handler = move |event: Event<'_, UserEvent>, _: &tao::event_loop::EventLoopWindowTarget<UserEvent>, control_flow: &mut ControlFlow| {
            *control_flow = ControlFlow::Wait;

            match event {
                Event::UserEvent(UserEvent::Token(token)) => {
                    if let Some(t) = tx_opt_loop.lock().take() {
                        let _ = t.send(Ok(token));
                    }
                    *control_flow = ControlFlow::Exit;
                }
                Event::UserEvent(UserEvent::Redirect(url)) => {
                    let _ = webview.load_url(&url);
                }
                Event::WindowEvent {
                    event: WindowEvent::CloseRequested,
                    ..
                } => {
                    *control_flow = ControlFlow::Exit;
                }
                _ => (),
            }
        };

        #[cfg(any(target_os = "windows", target_os = "linux"))]
        event_loop.run_return(event_handler);

        #[cfg(not(any(target_os = "windows", target_os = "linux")))]
        event_loop.run(event_handler);
    });

    match tokio::time::timeout(std::time::Duration::from_secs(600), rx).await {
        Ok(res) => res.map_err(|_| AppError::Unknown("Window closed without token".into()))?,
        Err(_) => Err(AppError::Unknown("Authorization timed out".into())),
    }
}
