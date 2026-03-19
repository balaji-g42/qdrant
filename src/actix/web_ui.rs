use std::path::{Path, PathBuf};

use actix_web::dev::HttpServiceFactory;
use actix_web::http::header::HeaderValue;
use actix_web::middleware::DefaultHeaders;
use actix_web::{HttpResponse, web};

use crate::settings::Settings;

const DEFAULT_STATIC_DIR: &str = "./static";
pub const WEB_UI_PATH: &str = "/dashboard";

pub fn web_ui_mount_path(base_path: &str) -> String {
    if base_path == "/" {
        WEB_UI_PATH.to_string()
    } else {
        format!("{base_path}{WEB_UI_PATH}")
    }
}

pub fn web_ui_folder(settings: &Settings) -> Option<String> {
    let web_ui_enabled = settings.service.enable_static_content.unwrap_or(true);

    if web_ui_enabled {
        let static_folder = settings
            .service
            .static_content_dir
            .clone()
            .unwrap_or_else(|| DEFAULT_STATIC_DIR.to_string());
        let static_folder_path = Path::new(&static_folder);
        if !static_folder_path.exists() || !static_folder_path.is_dir() {
            // enabled BUT folder does not exist
            log::warn!(
                "Static content folder for Web UI '{}' does not exist",
                static_folder_path.display(),
            );
            None
        } else {
            // enabled AND folder exists
            Some(static_folder)
        }
    } else {
        // not enabled
        None
    }
}

fn inject_base_path_runtime(html: &str, base_path: &str) -> String {
    if base_path == "/" {
        return html.to_string();
    }

    let js_base_path = serde_json::to_string(base_path).unwrap_or_else(|_| "\"/\"".to_string());
    let script = format!(
        r"<script>
(() => {{
  const BASE_PATH = {js_base_path};
  if (!BASE_PATH || BASE_PATH === '/') return;

  const toPathedUrl = (url) => {{
    try {{
      const parsed = new URL(url, window.location.origin);
      if (parsed.origin !== window.location.origin) return url;

      const path = parsed.pathname || '/';
      if (!path.startsWith('/')) return url;
      if (path === BASE_PATH || path.startsWith(BASE_PATH + '/')) return url;

      parsed.pathname = BASE_PATH + path;
      return parsed.pathname + parsed.search + parsed.hash;
    }} catch (_e) {{
      return url;
    }}
  }};

  const originalFetch = window.fetch.bind(window);
  window.fetch = (input, init) => {{
    if (typeof input === 'string') {{
      return originalFetch(toPathedUrl(input), init);
    }}

    if (input instanceof Request) {{
      const rewritten = toPathedUrl(input.url);
      if (rewritten === input.url) return originalFetch(input, init);
      return originalFetch(new Request(rewritten, input), init);
    }}

    return originalFetch(input, init);
  }};

  const originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url, ...rest) {{
    if (typeof url === 'string') {{
      return originalOpen.call(this, method, toPathedUrl(url), ...rest);
    }}
    return originalOpen.call(this, method, url, ...rest);
  }};
}})();
</script>"
    );

    if let Some(head_idx) = html.find("</head>") {
        let mut out = String::with_capacity(html.len() + script.len());
        out.push_str(&html[..head_idx]);
        out.push_str(&script);
        out.push_str(&html[head_idx..]);
        out
    } else {
        format!("{script}{html}")
    }
}

fn index_html_path(static_folder: &str) -> PathBuf {
    Path::new(static_folder).join("index.html")
}

fn index_html_response(static_folder: String, base_path: String) -> HttpResponse {
    let index_path = index_html_path(&static_folder);
    let Ok(raw_html) = fs_err::read_to_string(index_path) else {
        return HttpResponse::NotFound().finish();
    };

    let final_html = inject_base_path_runtime(&raw_html, &base_path);
    HttpResponse::Ok()
        .content_type("text/html; charset=utf-8")
        .body(final_html)
}

pub fn web_ui_factory(static_folder: &str, mount_path: &str) -> impl HttpServiceFactory + use<> {
    let static_folder = static_folder.to_string();
    let base_path = mount_path
        .strip_suffix(WEB_UI_PATH)
        .filter(|prefix| !prefix.is_empty())
        .unwrap_or("/")
        .to_string();

    web::scope(mount_path)
        .wrap(DefaultHeaders::new().add(("X-Frame-Options", HeaderValue::from_static("DENY"))))
        .route(
            "",
            web::get().to({
                let static_folder = static_folder.clone();
                let base_path = base_path.clone();
                move || index_html_response(static_folder.clone(), base_path.clone())
            }),
        )
        .route(
            "/",
            web::get().to({
                let static_folder = static_folder.clone();
                let base_path = base_path.clone();
                move || index_html_response(static_folder.clone(), base_path.clone())
            }),
        )
        .route(
            "/index.html",
            web::get().to({
                let static_folder = static_folder.clone();
                let base_path = base_path.clone();
                move || index_html_response(static_folder.clone(), base_path.clone())
            }),
        )
        .service(actix_files::Files::new("/", static_folder))
}

#[cfg(test)]
mod tests {
    use actix_web::App;
    use actix_web::http::StatusCode;
    use actix_web::http::header::{self, HeaderMap};
    use actix_web::test::{self, TestRequest};

    use super::*;

    fn assert_html_custom_headers(headers: &HeaderMap) {
        let content_type = header::HeaderValue::from_static("text/html; charset=utf-8");
        assert_eq!(headers.get(header::CONTENT_TYPE), Some(&content_type));
        let x_frame_options = header::HeaderValue::from_static("DENY");
        assert_eq!(headers.get(header::X_FRAME_OPTIONS), Some(&x_frame_options),);
    }

    #[actix_web::test]
    async fn test_web_ui() {
        let static_dir = String::from("static");
        let mut settings = Settings::new(None).unwrap();
        settings.service.static_content_dir = Some(static_dir.clone());

        let maybe_static_folder = web_ui_folder(&settings);
        if maybe_static_folder.is_none() {
            println!("Skipping test because the static folder was not found.");
            return;
        }

        let static_folder = maybe_static_folder.unwrap();
        let mount_path = web_ui_mount_path("/");
        let srv =
            test::init_service(App::new().service(web_ui_factory(&static_folder, &mount_path)))
                .await;

        // Index path (no trailing slash)
        let req = TestRequest::with_uri(&mount_path).to_request();
        let res = test::call_service(&srv, req).await;
        assert_eq!(res.status(), StatusCode::OK);
        let headers = res.headers();
        assert_html_custom_headers(headers);
        // Index path (trailing slash)
        let req = TestRequest::with_uri(format!("{mount_path}/").as_str()).to_request();
        let res = test::call_service(&srv, req).await;
        assert_eq!(res.status(), StatusCode::OK);
        let headers = res.headers();
        assert_html_custom_headers(headers);
        // Index path (index.html file)
        let req = TestRequest::with_uri(format!("{mount_path}/index.html").as_str()).to_request();
        let res = test::call_service(&srv, req).await;
        assert_eq!(res.status(), StatusCode::OK);
        let headers = res.headers();
        assert_html_custom_headers(headers);
        // Static asset (favicon.ico)
        let req = TestRequest::with_uri(format!("{mount_path}/favicon.ico").as_str()).to_request();
        let res = test::call_service(&srv, req).await;
        assert_eq!(res.status(), StatusCode::OK);
        let headers = res.headers();
        assert_eq!(
            headers.get(header::CONTENT_TYPE),
            Some(&header::HeaderValue::from_static("image/x-icon")),
        );
        // Non-existing path (404 Not Found)
        let fake_path = uuid::Uuid::new_v4().to_string();
        let srv =
            test::init_service(App::new().service(web_ui_factory(&fake_path, &mount_path))).await;

        let req = TestRequest::with_uri(&mount_path).to_request();
        let res = test::call_service(&srv, req).await;
        assert_eq!(res.status(), StatusCode::NOT_FOUND);
        let headers = res.headers();
        assert_eq!(headers.get(header::CONTENT_TYPE), None);
        assert_eq!(headers.get(header::CONTENT_LENGTH), None);
    }

    #[actix_web::test]
    async fn test_web_ui_custom_base_path() {
        let static_dir = String::from("static");
        let mut settings = Settings::new(None).unwrap();
        settings.service.static_content_dir = Some(static_dir.clone());

        let maybe_static_folder = web_ui_folder(&settings);
        if maybe_static_folder.is_none() {
            println!("Skipping test because the static folder was not found.");
            return;
        }

        let static_folder = maybe_static_folder.unwrap();
        let mount_path = web_ui_mount_path("/qdrant");
        let srv =
            test::init_service(App::new().service(web_ui_factory(&static_folder, &mount_path)))
                .await;

        let req = TestRequest::with_uri(&mount_path).to_request();
        let res = test::call_service(&srv, req).await;
        assert_eq!(res.status(), StatusCode::OK);

        let req = TestRequest::with_uri(format!("{mount_path}/index.html").as_str()).to_request();
        let res = test::call_service(&srv, req).await;
        assert_eq!(res.status(), StatusCode::OK);
    }

    #[actix_web::test]
    async fn test_web_ui_dual_mount_static_assets() {
        let static_dir = String::from("static");
        let mut settings = Settings::new(None).unwrap();
        settings.service.static_content_dir = Some(static_dir.clone());

        let maybe_static_folder = web_ui_folder(&settings);
        if maybe_static_folder.is_none() {
            println!("Skipping test because the static folder was not found.");
            return;
        }

        let static_folder = maybe_static_folder.unwrap();
        let legacy_mount = web_ui_mount_path("/");
        let custom_mount = web_ui_mount_path("/qdrant");

        let srv = test::init_service(
            App::new()
                .service(web_ui_factory(&static_folder, &legacy_mount))
                .service(web_ui_factory(&static_folder, &custom_mount)),
        )
        .await;

        let req =
            TestRequest::with_uri(format!("{legacy_mount}/favicon.ico").as_str()).to_request();
        let res = test::call_service(&srv, req).await;
        assert_eq!(res.status(), StatusCode::OK);

        let req =
            TestRequest::with_uri(format!("{custom_mount}/favicon.ico").as_str()).to_request();
        let res = test::call_service(&srv, req).await;
        assert_eq!(res.status(), StatusCode::OK);
    }

    #[test]
    fn test_inject_base_path_runtime() {
        let html = "<html><head><title>x</title></head><body>Hello</body></html>";

        let same = inject_base_path_runtime(html, "/");
        assert_eq!(same, html);

        let injected = inject_base_path_runtime(html, "/qdrant");
        assert!(injected.contains("const BASE_PATH = \"/qdrant\";"));
        assert!(injected.contains("window.fetch"));
        assert!(injected.contains("XMLHttpRequest.prototype.open"));
    }
}
