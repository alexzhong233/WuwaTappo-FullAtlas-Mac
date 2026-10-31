//! Official 1.0.3 shortcut contract. Uses the existing listen-only input tap;
//! never registers a second count stream or injects OS input.
use serde::{Deserialize, Serialize};
use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf, sync::Mutex};
use tauri::{AppHandle, Emitter, Manager, State, WebviewWindow};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Binding {
    modifiers: u8,
    key: u16,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    game_mode: Binding,
    switch_screen: Binding,
    toggle_pet: Binding,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            game_mode: Binding {
                modifiers: 0,
                key: 118,
            },
            switch_screen: Binding {
                modifiers: 0,
                key: 119,
            },
            toggle_pet: Binding {
                modifiers: 0,
                key: 120,
            },
        }
    }
}
impl Config {
    fn entries(&self) -> [(&'static str, Binding); 3] {
        [
            ("gameMode", self.game_mode),
            ("switchScreen", self.switch_screen),
            ("togglePet", self.toggle_pet),
        ]
    }
    fn validate(&self) -> Result<(), String> {
        let entries = self.entries();
        for (i, (_, binding)) in entries.iter().enumerate() {
            if binding.modifiers > 15 || (binding.key == 0 && binding.modifiers != 0) {
                return Err("invalid".into());
            }
            if binding.key == 0 {
                continue;
            }
            if !supported_vk(binding.key)
                || (!(112..=131).contains(&binding.key) && binding.modifiers & 11 == 0)
            {
                return Err("invalid".into());
            }
            if entries[..i].iter().any(|(_, other)| binding == other) {
                return Err("duplicate".into());
            }
        }
        Ok(())
    }
    fn action(&self, key: &str, flags: u64) -> Option<&'static str> {
        let key = virtual_key(key)?;
        let modifiers = modifiers(flags);
        self.entries()
            .into_iter()
            .find(|(_, b)| b.key != 0 && b.key == key && b.modifiers == modifiers)
            .map(|(a, _)| a)
    }
}
fn supported_vk(key: u16) -> bool {
    matches!(key, 32..=40 | 46 | 48..=57 | 65..=90 | 112..=131 | 186..=192 | 219..=222)
}
fn modifiers(flags: u64) -> u8 {
    ((flags & (1 << 19) != 0) as u8)
        | (((flags & (1 << 18) != 0) as u8) << 1)
        | (((flags & (1 << 17) != 0) as u8) << 2)
        | (((flags & (1 << 20) != 0) as u8) << 3)
}
fn virtual_key(label: &str) -> Option<u16> {
    if let Some(number) = label.strip_prefix('F').and_then(|v| v.parse::<u16>().ok()) {
        return (1..=20).contains(&number).then_some(111 + number);
    }
    if label.len() == 1 {
        let byte = label.as_bytes()[0];
        if byte.is_ascii_alphanumeric() {
            return Some(byte.to_ascii_uppercase() as u16);
        }
    }
    Some(match label {
        " " => 32,
        "PageUp" => 33,
        "PageDown" => 34,
        "End" => 35,
        "Home" => 36,
        "ArrowLeft" => 37,
        "ArrowUp" => 38,
        "ArrowRight" => 39,
        "ArrowDown" => 40,
        "Delete" => 46,
        ";" => 186,
        "=" => 187,
        "," => 188,
        "-" => 189,
        "." => 190,
        "/" => 191,
        "`" => 192,
        "[" => 219,
        "\\" => 220,
        "]" => 221,
        "'" => 222,
        _ => return None,
    })
}
pub struct Shortcuts {
    config: Mutex<Config>,
    capture: Mutex<Option<String>>,
    path: PathBuf,
}
impl Shortcuts {
    pub fn new(path: PathBuf) -> Result<Self, String> {
        let config = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice::<Config>(&bytes)
                .map_err(|e| format!("shortcuts.json: {e}"))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Config::default(),
            Err(e) => return Err(e.to_string()),
        };
        config.validate()?;
        Ok(Self {
            config: Mutex::new(config),
            capture: Mutex::new(None),
            path,
        })
    }
    pub fn trigger(&self, app: &AppHandle, key: &str, flags: u64) {
        let capture = self.capture.lock().unwrap_or_else(|e| e.into_inner());
        if capture.as_ref().is_some_and(|label| {
            app.get_webview_window(label)
                .is_some_and(|w| w.is_visible().unwrap_or(false) && w.is_focused().unwrap_or(false))
        }) {
            return;
        }
        drop(capture);
        let config = self.config.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(action) = config.action(key, flags) {
            let _ = app.emit_to("main", "app-shortcut", action);
        }
    }
}
fn local(window: &WebviewWindow) -> Result<(), String> {
    let url = window.url().map_err(|e| e.to_string())?;
    if !matches!(window.label(), "main" | "panel")
        || !((url.scheme() == "tauri" && url.host_str() == Some("localhost"))
            || (matches!(url.scheme(), "https" | "http")
                && url.host_str() == Some("tauri.localhost")))
        || url.port().is_some()
    {
        return Err("shortcuts require a local main/panel window".into());
    }
    Ok(())
}
#[tauri::command]
pub fn get_app_shortcuts(
    window: WebviewWindow,
    state: State<'_, Shortcuts>,
) -> Result<Config, String> {
    local(&window)?;
    Ok(state
        .config
        .lock()
        .map_err(|_| "shortcut lock failed")?
        .clone())
}
#[tauri::command]
pub fn set_app_shortcuts(
    app: AppHandle,
    window: WebviewWindow,
    state: State<'_, Shortcuts>,
    config: Config,
) -> Result<(), String> {
    local(&window)?;
    config.validate()?;
    let mut saved = state.config.lock().map_err(|_| "shortcut lock failed")?;
    fs::create_dir_all(state.path.parent().ok_or("missing shortcut directory")?)
        .map_err(|e| e.to_string())?;
    let tmp = state.path.with_extension("tmp");
    fs::write(
        &tmp,
        serde_json::to_vec(&config).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    fs::rename(tmp, &state.path).map_err(|e| e.to_string())?;
    *saved = config.clone();
    app.emit("app-shortcuts-changed", config)
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub fn set_shortcut_capture(
    window: WebviewWindow,
    state: State<'_, Shortcuts>,
    active: bool,
) -> Result<(), String> {
    local(&window)?;
    let mut capture = state
        .capture
        .lock()
        .map_err(|_| "shortcut capture lock failed")?;
    if active {
        *capture = Some(window.label().into());
    } else if capture.as_deref() == Some(window.label()) {
        *capture = None;
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn defaults_and_modifier_mapping_match_official_contract() {
        let c = Config::default();
        c.validate().unwrap();
        assert_eq!(c.action("F7", 0), Some("gameMode"));
        assert_eq!(c.action("F8", 0), Some("switchScreen"));
        assert_eq!(c.action("F9", 0), Some("togglePet"));
        assert_eq!(c.action("F8", 1 << 20), None);
        assert_eq!(modifiers((1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)), 15);
        assert_eq!(virtual_key("a"), Some(65));
        assert_eq!(virtual_key("ShiftLeft"), None);
    }
    #[test]
    fn invalid_and_duplicate_bindings_are_rejected() {
        let mut c = Config::default();
        c.toggle_pet = c.game_mode;
        assert_eq!(c.validate().unwrap_err(), "duplicate");
        c.toggle_pet = Binding {
            modifiers: 0,
            key: 65,
        };
        assert!(c.validate().is_err());
        c.toggle_pet.modifiers = 8;
        c.validate().unwrap();
        assert_eq!(c.action("a", 1 << 20), Some("togglePet"));
        c.toggle_pet.key = 0;
        assert!(c.validate().is_err());
        c.toggle_pet.modifiers = 0;
        c.validate().unwrap();
    }
}
