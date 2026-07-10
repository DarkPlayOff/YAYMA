fn is_newer_version(current: &str, latest: &str) -> bool {
    let clean = |v: &str| -> String {
        let mut cleaned = v.trim().to_lowercase();
        if cleaned.starts_with('v') {
            cleaned.remove(0);
        }
        if let Some(pos) = cleaned.find('+') {
            cleaned.truncate(pos);
        }
        cleaned
    };

    let cur_clean = clean(current);
    let lat_clean = clean(latest);

    let cur_parts: Vec<i32> = cur_clean.split('.').map(|s| s.parse().unwrap_or(0)).collect();
    let lat_parts: Vec<i32> = lat_clean.split('.').map(|s| s.parse().unwrap_or(0)).collect();

    let max_len = std::cmp::max(cur_parts.len(), lat_parts.len());
    for i in 0..max_len {
        let cur_val = *cur_parts.get(i).unwrap_or(&0);
        let lat_val = *lat_parts.get(i).unwrap_or(&0);
        if lat_val > cur_val {
            return true;
        }
        if lat_val < cur_val {
            return false;
        }
    }
    false
}

pub async fn check_for_updates() -> Option<crate::api::updates::AppUpdateInfoDto> {
    let client = reqwest::Client::builder()
        .user_agent("yayma-app")
        .build()
        .ok()?;

    let res = client
        .get("https://api.github.com/repos/DarkPlayOff/YAYMA/releases/latest")
        .header("Accept", "application/vnd.github.v3+json")
        .send()
        .await
        .ok()?;

    if !res.status().is_success() {
        return None;
    }

    #[derive(serde::Deserialize)]
    struct GithubRelease {
        tag_name: String,
        body: Option<String>,
        html_url: String,
    }

    let release: GithubRelease = res.json().await.ok()?;
    let current_version = crate::app::logic::simple::get_app_version();
    let has_update = is_newer_version(&current_version, &release.tag_name);

    Some(crate::api::updates::AppUpdateInfoDto {
        latest_version: release.tag_name,
        changelog: release.body.unwrap_or_default(),
        url: release.html_url,
        has_update,
    })
}
