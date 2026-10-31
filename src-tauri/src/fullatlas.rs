//! Native transport and state for the MIT FullAtlas controllers. No localhost
//! HTTP server, OS input injection, Windows updater, or simulated rewards.
use chrono::{Duration as Days, Local};
use reqwest::Url;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs,
    io::Read,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tauri::{AppHandle, Emitter, Manager, WebviewWindow};

const UPDATE_MESSAGE: &str =
    "这是 Mac 整合版；Windows FullAtlas 更新包不能安装到 Mac。请使用本项目的 Mac 安装包更新。";
const MAX_JSON: u64 = 16 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
struct Settings {
    enabled: bool,
    speed: u32,
    auto_chest: bool,
    threshold: u64,
    remember_monitor: bool,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            enabled: false,
            speed: 5,
            auto_chest: false,
            threshold: 1000,
            remember_monitor: true,
        }
    }
}

#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct Saved {
    settings: Settings,
    enabled: bool,
    session: u64,
    confirmed: u64,
    session_chests: u64,
    rewards: Vec<Value>,
    rooms: Vec<Value>,
    monitor: Option<Value>,
    baselines: BTreeMap<String, u64>,
    days: BTreeMap<String, u64>,
}
#[derive(Default)]
struct Runtime {
    account: String,
    values: Value,
    next_tick: Option<Instant>,
    flush_generation: u64,
    flush_done: u64,
    last_save: Option<Instant>,
}
struct Inner {
    saved: Saved,
    runtime: Runtime,
}
pub struct FullAtlasState {
    dir: PathBuf,
    inner: Mutex<Inner>,
    catalog: Mutex<Option<Value>>,
}

fn unix_time() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn atomic_json(path: &Path, value: &impl Serialize) -> Result<(), String> {
    fs::create_dir_all(path.parent().ok_or("Missing state directory")?)
        .map_err(|e| e.to_string())?;
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, serde_json::to_vec(value).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    fs::rename(tmp, path).map_err(|e| e.to_string())
}
fn local_window(label: &str, url: &Url) -> bool {
    matches!(label, "main" | "panel")
        && url.port().is_none()
        && ((url.scheme() == "tauri" && url.host_str() == Some("localhost"))
            || (matches!(url.scheme(), "http" | "https")
                && url.host_str() == Some("tauri.localhost")))
}
fn trusted_asset_url(region: crate::profile::Region, url: &str) -> Result<Url, String> {
    let url = Url::parse(url).map_err(|_| "图鉴地址无效")?;
    if url.scheme() != "https"
        || url.host_str() != Some(region.asset_host())
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err("图鉴目录地址不是当前地区官方素材源".into());
    }
    Ok(url)
}
fn get_json(client: &reqwest::blocking::Client, url: Url) -> Result<Value, String> {
    let response = client
        .get(url)
        .send()
        .map_err(|e| format!("读取图鉴失败：{e}"))?
        .error_for_status()
        .map_err(|e| format!("图鉴响应失败：{e}"))?;
    if response.content_length().is_some_and(|n| n > MAX_JSON) {
        return Err("图鉴目录超出大小限制".into());
    }
    let mut bytes = Vec::new();
    response
        .take(MAX_JSON + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_JSON {
        return Err("图鉴目录超出大小限制".into());
    }
    serde_json::from_slice(&bytes).map_err(|e| format!("图鉴 JSON 无效：{e}"))
}

fn official_update_status(region: crate::profile::Region) -> Result<Value, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("WuwaTappo-FullAtlas-Mac")
        .build()
        .map_err(|e| e.to_string())?;
    let api = format!("https://{}", region.api_host());
    let activity = get_json(
        &client,
        Url::parse(&format!("{api}/api/common/activity-config")).map_err(|e| e.to_string())?,
    )?;
    let host = activity
        .pointer("/data/assets_host")
        .and_then(Value::as_str)
        .ok_or("官方版本检查缺少资源源")?
        .trim_end_matches('/');
    let host = trusted_asset_url(region, host)?;
    let pointer = get_json(
        &client,
        trusted_asset_url(
            region,
            &format!("{}/app/json-host/{}", host, region.updater_host_file()),
        )?,
    )?;
    let manifest_url = pointer
        .get("url")
        .and_then(Value::as_str)
        .ok_or("官方版本检查缺少版本清单")?;
    let manifest_url = trusted_asset_url(region, manifest_url)?;
    let manifest = get_json(&client, manifest_url)?;
    let latest = manifest
        .get("version")
        .and_then(Value::as_str)
        .ok_or("官方版本清单无效")?;
    let current = env!("WUWA_OFFICIAL_VERSION");
    let changed = latest != current;
    Ok(json!({
        "currentVersion": current,
        "latestVersion": latest,
        "updateAvailable": changed,
        "message": if changed { format!("检测到官方 {latest}，需要维护者重新适配并发布 Mac 包。") } else { format!("官方基底已是 {current}。") },
    }))
}
fn validate_catalog(value: &Value) -> Result<(), String> {
    let atlas = value
        .get("atlas")
        .and_then(Value::as_array)
        .filter(|a| !a.is_empty())
        .ok_or("官方图鉴列表为空")?;
    let catalog = value.get("catalog").ok_or("缺少外观目录")?;
    for kind in ["character_skin", "accessory", "emote"] {
        if !catalog.get(kind).is_some_and(Value::is_object)
            || !catalog
                .get(format!("{kind}_atlas"))
                .is_some_and(Value::is_object)
        {
            return Err("外观目录结构不兼容，原缓存保留".into());
        }
    }
    for row in atlas {
        let kind = row
            .get("asset_type")
            .and_then(Value::as_str)
            .ok_or("图鉴类型缺失")?;
        let id = row
            .get("asset_id")
            .and_then(Value::as_u64)
            .ok_or("图鉴 ID 无效")?
            .to_string();
        let usable = catalog
            .get(kind)
            .and_then(|v| v.get(&id))
            .and_then(|v| v.get("height_light_id"))
            .and_then(Value::as_u64)
            .ok_or("图鉴缺少外观 ID 映射")?
            .to_string();
        if !catalog
            .get(kind.trim_end_matches("_atlas"))
            .is_some_and(|v| v.get(usable).is_some())
        {
            return Err("图鉴外观映射不完整，原缓存保留".into());
        }
    }
    Ok(())
}

impl FullAtlasState {
    pub fn new(dir: PathBuf) -> Result<Self, String> {
        let path = dir.join("fullatlas.json");
        let saved = if path.exists() {
            serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?)
                .map_err(|e| format!("FullAtlas 状态文件损坏，请备份后修复：{e}"))?
        } else {
            Saved::default()
        };
        Ok(Self {
            dir,
            inner: Mutex::new(Inner {
                saved,
                runtime: Runtime::default(),
            }),
            catalog: Mutex::new(None),
        })
    }
    pub fn enabled(&self) -> bool {
        self.inner.lock().map(|v| v.saved.enabled).unwrap_or(true)
    }
    fn save(&self, inner: &mut Inner, force: bool) -> Result<(), String> {
        if force
            || inner
                .runtime
                .last_save
                .is_none_or(|t| t.elapsed() >= Duration::from_secs(5))
        {
            atomic_json(&self.dir.join("fullatlas.json"), &inner.saved)?;
            inner.runtime.last_save = Some(Instant::now());
        }
        Ok(())
    }
    fn catalog(&self, app: &AppHandle, refresh: bool) -> Result<Value, String> {
        let mut memo = self.catalog.lock().map_err(|_| "图鉴缓存锁失败")?;
        if !refresh {
            if let Some(value) = memo.as_ref() {
                return Ok(value.clone());
            }
        }
        let path = self.dir.join("fullatlas-catalog.json");
        if !refresh {
            let bundled = app
                .path()
                .resource_dir()
                .map_err(|e| e.to_string())?
                .join("fullatlas-catalog.json");
            for source in [&path, &bundled] {
                if let Ok(bytes) = fs::read(source) {
                    if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
                        if validate_catalog(&value).is_ok()
                            && value.get("assets_host").and_then(Value::as_str)
                                == Some(
                                    format!(
                                        "https://{}",
                                        crate::profile::Region::from_app(app).asset_host()
                                    )
                                    .as_str(),
                                )
                        {
                            *memo = Some(value.clone());
                            return Ok(value);
                        }
                    }
                }
            }
        }
        let region = crate::profile::Region::from_app(app);
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::none())
            .user_agent("WuwaTappo-FullAtlas-Mac")
            .build()
            .map_err(|e| e.to_string())?;
        let api = format!("https://{}", region.api_host());
        let activity = get_json(
            &client,
            Url::parse(&format!("{api}/api/common/activity-config")).map_err(|e| e.to_string())?,
        )?;
        let atlas = get_json(
            &client,
            Url::parse(&format!("{api}/api/common/atlas")).map_err(|e| e.to_string())?,
        )?;
        if activity.get("code") != Some(&json!(0)) || atlas.get("code") != Some(&json!(0)) {
            return Err("官方目录请求失败，原缓存保留".into());
        }
        let host = activity
            .pointer("/data/assets_host")
            .and_then(Value::as_str)
            .ok_or("官方素材源缺失")?
            .trim_end_matches('/');
        trusted_asset_url(region, host)?;
        let pointer = get_json(
            &client,
            trusted_asset_url(
                region,
                &format!("{host}/app/json-host/appearance_asset_host.json"),
            )?,
        )?;
        let url = pointer
            .get("url")
            .and_then(Value::as_str)
            .ok_or("官方目录地址缺失")?;
        let catalog = get_json(&client, trusted_asset_url(region, url)?)?;
        let value = json!({"atlas":atlas["data"], "catalog":catalog, "assets_host":host, "assets_json_ts":activity.pointer("/data/assets_json_ts"), "checked_at":unix_time()});
        validate_catalog(&value)?;
        atomic_json(&path, &value)?;
        *memo = Some(value.clone());
        Ok(value)
    }
    fn snapshot(inner: &Inner) -> Value {
        let today = Local::now().date_naive();
        let weekly: Vec<Value> = (0..7)
            .rev()
            .map(|n| {
                let day = (today - Days::days(n)).to_string();
                json!({"count":inner.saved.days.get(&day).copied().unwrap_or(0), "date":day})
            })
            .collect();
        json!({"settings":inner.saved.settings, "session":inner.saved.session, "confirmed":inner.saved.confirmed, "session_chests":inner.saved.session_chests,
            "rewards":inner.saved.rewards, "rooms":inner.saved.rooms, "monitor":inner.saved.monitor, "runtime":inner.runtime.values,
            "flush_generation":inner.runtime.flush_generation, "flush_done":inner.runtime.flush_done, "weekly":{"normal":weekly}, "update_required":false})
    }
    fn assistant(&self, action: &str, body: &Value, physical_quiet: bool) -> Result<Value, String> {
        let mut inner = self.inner.lock().map_err(|_| "全图鉴数据锁失败")?;
        match action {
            "state" | "renderer-start" => return Ok(Self::snapshot(&inner)),
            "configure" => {
                let changes = body
                    .get("settings")
                    .and_then(Value::as_object)
                    .ok_or("设置必须是对象")?;
                let mut next = inner.saved.settings.clone();
                for (key, val) in changes {
                    match key.as_str() {
                        "enabled" => next.enabled = val.as_bool().ok_or("enabled 必须是布尔值")?,
                        "auto_chest" => {
                            next.auto_chest = val.as_bool().ok_or("auto_chest 必须是布尔值")?
                        }
                        "remember_monitor" => {
                            next.remember_monitor =
                                val.as_bool().ok_or("remember_monitor 必须是布尔值")?
                        }
                        "speed" => {
                            let speed = val
                                .as_u64()
                                .filter(|v| [1, 5, 10].contains(v))
                                .ok_or("速度必须是 1、5 或 10")?;
                            next.speed = speed as u32;
                        }
                        "threshold" => {
                            next.threshold = val
                                .as_u64()
                                .filter(|v| (1..=1_000_000_000).contains(v))
                                .ok_or("开箱阈值无效")?
                        }
                        _ => return Err(format!("未知设置：{key}")),
                    }
                }
                inner.saved.settings = next;
            }
            "tick" | "observe" => {
                let sent = body.get("sent").and_then(Value::as_u64).unwrap_or(0);
                let confirmed = body.get("confirmed").and_then(Value::as_u64).unwrap_or(0);
                if sent > 1 || confirmed > sent {
                    return Err("点击确认值无效".into());
                }
                inner.saved.session = inner.saved.session.saturating_add(sent);
                inner.saved.confirmed = inner.saved.confirmed.saturating_add(confirmed);
                if let Some(total) = body.get("total").and_then(Value::as_u64) {
                    if total > 9_007_199_254_740_991 {
                        return Err("累计点击值超出有效范围".into());
                    }
                    let account = body
                        .get("account")
                        .and_then(Value::as_str)
                        .unwrap_or("guest");
                    if account.len() > 200 {
                        return Err("账号标识过长".into());
                    }
                    inner.runtime.account = account.into();
                    if let Some(before) = inner.saved.baselines.insert(account.into(), total) {
                        if total >= before {
                            *inner
                                .saved
                                .days
                                .entry(Local::now().date_naive().to_string())
                                .or_default() += total - before;
                        }
                    }
                    if inner.saved.baselines.len() > 100 {
                        inner.saved.baselines.retain(|key, _| key == account);
                    }
                    let cutoff = (Local::now().date_naive() - Days::days(90)).to_string();
                    inner.saved.days.retain(|date, _| date >= &cutoff);
                    inner.runtime.values = json!({"total":total,"balance":body