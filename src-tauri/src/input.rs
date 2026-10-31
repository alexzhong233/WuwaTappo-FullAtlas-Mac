use serde::Serialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::c_void,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc, Arc, Mutex,
    },
    thread::{self, JoinHandle},
};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct InputStatus {
    pub granted: bool,
    pub running: bool,
    pub error: Option<String>,
}

pub fn physical_input_quiet() -> bool {
    if unsafe { CGEventSourceSecondsSinceLastEventType(0, u32::MAX) } < 0.25 {
        return false;
    }
    !(0u16..=255).any(|key| unsafe { CGEventSourceKeyState(0, key) })
        && !(0..32).any(|button| unsafe { CGEventSourceButtonState(0, button) })
}

fn input_status_snapshot(
    granted: bool,
    worker_running: bool,
    tap_enabled: bool,
    recorded_error: Option<String>,
) -> InputStatus {
    let running = granted && worker_running && tap_enabled;
    let error = if !granted {
        Some(
            if worker_running {
                "input_monitoring_permission_revoked"
            } else {
                "input_monitoring_permission_required"
            }
            .into(),
        )
    } else if running {
        None
    } else if worker_running && !tap_enabled {
        Some("input_event_tap_disabled".into())
    } else {
        match recorded_error.as_deref() {
            Some(
                "input_monitoring_permission_required" | "input_monitoring_permission_revoked",
            ) => Some("input_access_granted_waiting_for_resume".into()),
            Some(_) => recorded_error,
            None => Some("input_monitor_not_running".into()),
        }
    };
    InputStatus {
        granted,
        running,
        error,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct MousePosition {
    pub x: f64,
    pub y: f64,
    #[serde(rename = "memberId", skip_serializing_if = "Option::is_none")]
    pub member_id: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
struct MouseButton {
    button: &'static str,
    action: &'static str,
    #[serde(rename = "memberId", skip_serializing_if = "Option::is_none")]
    member_id: Option<u64>,
}

type MemberResolver = Arc<dyn Fn(f64, f64) -> Option<u64> + Send + Sync>;
type AuxiliaryHitTest = Arc<dyn Fn(f64, f64) -> bool + Send + Sync>;

struct MonitorState {
    running: AtomicBool,
    stop: AtomicBool,
    scale: AtomicU64,
    window_listener_installed: AtomicBool,
    run_loop: Mutex<usize>,
    event_tap: Mutex<usize>,
    error: Mutex<Option<String>>,
    member_resolver: Mutex<Option<MemberResolver>>,
    auxiliary_hit_test: Mutex<Option<AuxiliaryHitTest>>,
}

impl MonitorState {
    fn error(&self, message: String) {
        if let Ok(mut error) = self.error.lock() {
            *error = Some(message);
        }
    }

    fn status(&self) -> InputStatus {
        let granted = unsafe { CGPreflightListenEventAccess() };
        let worker_running = self.running.load(Ordering::Acquire);
        let mut recorded_error = match self.error.lock() {
            Ok(error) => error.clone(),
            Err(_) => Some("input_status_lock_poisoned".into()),
        };
        let tap_enabled = match self.event_tap.lock() {
            Ok(tap) => *tap != 0 && unsafe { CGEventTapIsEnabled(*tap as *mut c_void) },
            Err(_) => {
                recorded_error = Some("input_event_tap_lock_poisoned".into());
                false
            }
        };
        input_status_snapshot(granted, worker_running, tap_enabled, recorded_error)
    }

    fn wake_and_stop(&self) {
        self.stop.store(true, Ordering::Release);
        if let Ok(run_loop) = self.run_loop.lock() {
            if *run_loop != 0 {
                // The worker retains this run loop while its pointer is in the mutex.
                unsafe {
                    CFRunLoopStop(*run_loop as *mut c_void);
                    CFRunLoopWakeUp(*run_loop as *mut c_void);
                }
            }
        }
    }
}

pub struct InputMonitor {
    state: Arc<MonitorState>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

impl Default for InputMonitor {
    fn default() -> Self {
        Self::new()
    }
}

impl InputMonitor {
    pub fn new() -> Self {
        Self {
            state: Arc::new(MonitorState {
                running: AtomicBool::new(false),
                stop: AtomicBool::new(false),
                scale: AtomicU64::new(1.0f64.to_bits()),
                window_listener_installed: AtomicBool::new(false),
                run_loop: Mutex::new(0),
                event_tap: Mutex::new(0),
                error: Mutex::new(None),
                member_resolver: Mutex::new(None),
                auxiliary_hit_test: Mutex::new(None),
            }),
            worker: Mutex::new(None),
        }
    }

    pub fn set_member_resolver<F>(&self, resolver: F) -> Result<(), String>
    where
        F: Fn(f64, f64) -> Option<u64> + Send + Sync + 'static,
    {
        *self
            .state
            .member_resolver
            .lock()
            .map_err(|_| "input_router_lock_poisoned")? = Some(Arc::new(resolver));
        Ok(())
    }

    pub fn set_auxiliary_hit_test<F>(&self, hit_test: F) -> Result<(), String>
    where
        F: Fn(f64, f64) -> bool + Send + Sync + 'static,
    {
        *self
            .state
            .auxiliary_hit_test
            .lock()
            .map_err(|_| "input_auxiliary_hit_test_lock_poisoned")? = Some(Arc::new(hit_test));
        Ok(())
    }

    pub fn status(&self) -> InputStatus {
        self.state.status()
    }

    pub fn start(&self, app: AppHandle) -> Result<InputStatus, String> {
        let result = self.start_inner(app.clone());
        if let Err(error) = &result {
            self.state.error(error.clone());
        }
        let status = self.emit_status(&app)?;
        result.map(|_| status)
    }

    fn start_inner(&self, app: AppHandle) -> Result<InputStatus, String> {
        let mut worker = self
            .worker
            .lock()
            .map_err(|_| "input_worker_lock_poisoned")?;
        if self.status().running {
            return Ok(self.status());
        }
        if let Some(previous) = worker.take() {
            self.state.wake_and_stop();
            previous.join().map_err(|_| "input_worker_panicked")?;
        }
        if !unsafe { CGPreflightListenEventAccess() } {
            self.state
                .error("input_monitoring_permission_required".into());
            return Ok(self.status());
        }
        let window = app
            .get_webview_window("main")
            .ok_or("main_window_missing")?;
        let scale = window
            .scale_factor()
            .map_err(|error| format!("input_window_scale_failed: {error}"))?;
        self.state.scale.store(scale.to_bits(), Ordering::Release);
        if !self
            .state
            .window_listener_installed
            .swap(true, Ordering::AcqRel)
        {
            let state = self.state.clone();
            window.on_window_event(move |event| {
                if let tauri::WindowEvent::ScaleFactorChanged { scale_factor, .. } = event {
                    state.scale.store(scale_factor.to_bits(), Ordering::Release);
                }
            });
        }
        self.state.stop.store(false, Ordering::Release);
        *self
            .state
            .error
            .lock()
            .map_err(|_| "input_status_lock_poisoned")? = None;
        let state = self.state.clone();
        let worker_app = app.clone();
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        *worker = Some(
            thread::Builder::new()
                .name("wuwatappo-input".into())
                .spawn(move || {
                    run_monitor(worker_app, state, ready_sender);
                })
                .map_err(|error| format!("input_worker_spawn_failed: {error}"))?,
        );
        let initialized = ready_receiver
            .recv()
            .map_err(|_| "input_worker_initialization_failed")?;
        initialized.map(|()| self.status())
    }

    fn emit_status(&self, app: &AppHandle) -> Result<InputStatus, String> {
        let status = self.status();
        app.emit("mac-input-status", &status)
            .map_err(|error| format!("input_status_delivery_failed: {error}"))?;
        Ok(status)
    }

    pub fn stop(&self) -> Result<(), String> {
        let mut worker = self
            .worker
            .lock()
            .map_err(|_| "input_worker_lock_poisoned")?;
        self.state.wake_and_stop();
        if let Some(worker) = worker.take() {
            worker.join().map_err(|_| "input_worker_panicked")?;
        }
        Ok(())
    }
}

impl Drop for InputMonitor {
    fn drop(&mut self) {
        if let Err(error) = self.stop() {
            self.state.error(error);
        }
    }
}

pub fn start(app: AppHandle) -> Result<InputStatus, String> {
    let monitor = app.state::<InputMonitor>();
    monitor.start(app.clone())
}

#[tauri::command]
pub fn get_input_status(app: AppHandle) -> InputStatus {
    app.state::<InputMonitor>().status()
}

#[tauri::command]
pub fn resume_input_monitor(app: AppHandle) -> Result<InputStatus, String> {
    // Recheck existing permission only; this path never requests access.
    start(app)
}

#[tauri::command]
pub fn request_input_access(app: AppHandle) -> Result<InputStatus, String> {
    // This is the only permission-requesting path, invoked by an explicit app action.
    if !unsafe { CGPreflightListenEventAccess() } {
        unsafe {
            CGRequestListenEventAccess();
        }
    }
    start(app)
}

#[derive(Debug)]
enum NativeInput {
    Shortcut {
        key: String,
        flags: u64,
    },
    Key {
        key: String,
        pressed: bool,
    },
    Move(Point),
    Button {
        point: Point,
        button: &'static str,
        pressed: bool,
    },
}

#[derive(Clone, Copy, Debug)]
#[repr(C)]
struct Point {
    x: f64,
    y: f64,
}

struct TapContext {
    sender: mpsc::Sender<NativeInput>,
    state: Arc<MonitorState>,
    tap: *mut c_void,
    pressed: BTreeSet<u16>,
}

impl TapContext {
    fn send(&self, event: NativeInput) {
        if self.sender.send(event).is_err() {
            self.state.error("input_dispatch_disconnected".into());
            self.state.wake_and_stop();
        }
    }

    fn release_keys(&mut self) {
        for code in std::mem::take(&mut self.pressed) {
            self.send(NativeInput::Key {
                key: key_label(code),
                pressed: false,
            });
        }
    }
}

unsafe extern "C" fn observe_event(
    _proxy: *mut c_void,
    event_type: u32,
    event: *mut c_void,
    context: *mut c_void,
) -> *mut c_void {
    let context = unsafe { &mut *(context as *mut TapContext) };
    if event_type == 0xffff_fffe || event_type == 0xffff_ffff {
        context.release_keys();
        if unsafe { CGPreflightListenEventAccess() } {
            unsafe {
                CGEventTapEnable(context.tap, true);
            }
        } else {
            context
                .state
                .error("input_monitoring_permission_revoked".into());
            context.state.wake_and_stop();
        }
        return event;
    }
    if event.is_null() || context.state.stop.load(Ordering::Acquire) {
        return event;
    }
    match event_type {
        10 | 11 | 12 => {
            let code = unsafe { CGEventGetIntegerValueField(event, 9) } as u16;
            if event_type == 12 && code == 57 {
                // Caps Lock sends a flag transition, not a normal down/up pair.
                context.send(NativeInput::Key {
                    key: key_label(code),
                    pressed: true,
                });
                context.send(NativeInput::Key {
                    key: key_label(code),
                    pressed: false,
                });
                return event;
            }
            let pressed = if event_type == 12 {
                unsafe { CGEventSourceKeyState(0, code) }
            } else {
                event_type == 10
            };
            if pressed {
                if context.pressed.insert(code) {
                    context.send(NativeInput::Shortcut {
                        key: key_label(code),
                        flags: unsafe { CGEventGetFlags(event) },
                    });
                    context.send(NativeInput::Key {
                        key: key_label(code),
                        pressed: true,
                    });
                }
            } else if context.pressed.remove(&code) {
                context.send(NativeInput::Key {
                    key: key_label(code),
                    pressed: false,
                });
            }
        }
        1 | 2 | 3 | 4 | 25 | 26 => {
            let button = match event_type {
                1 | 2 => "left",
                3 | 4 => "right",
                _ => "middle",
            };
            // OtherMouse events can also represent extra side buttons; preserve only the supported middle button.
            if matches!(event_type, 25 | 26)
                && unsafe { CGEventGetIntegerValueField(event, 3) } != 2
            {
                return event;
            }
            context.send(NativeInput::Button {
                point: unsafe { CGEventGetLocation(event) },
                button,
                pressed: matches!(event_type, 1 | 3 | 25),
            });
        }
        5 | 6 | 7 | 27 => context.send(NativeInput::Move(unsafe { CGEventGetLocation(event) })),
        _ => {}
    }
    event
}

fn run_monitor(
    app: AppHandle,
    state: Arc<MonitorState>,
    ready: mpsc::SyncSender<Result<(), String>>,
) {
    let (sender, receiver) = mpsc::channel();
    let mut context = Box::new(TapContext {
        sender,
        state: state.clone(),
        tap: std::ptr::null_mut(),
        pressed: BTreeSet::new(),
    });
    let mask = [1u32, 2, 3, 4, 5, 6, 7, 10, 11, 12, 25, 26, 27]
        .into_iter()
        .fold(0u64, |mask, event| mask | (1u64 << event));
    let tap = unsafe {
        CGEventTapCreate(
            1,
            0,
            1,
            mask,
            observe_event,
            (&mut *context as *mut TapContext).cast(),
        )
    };
    if tap.is_null() {
        let error = "input_event_tap_create_failed".to_owned();
        state.error(error.clone());
        let _ = ready.send(Err(error));
        return;
    }
    context.tap = tap;
    let source = unsafe { CFMachPortCreateRunLoopSource(std::ptr::null_mut(), tap, 0) };
    if source.is_null() {
        unsafe {
            CFMachPortInvalidate(tap);
            CFRelease(tap);
        }
        let error = "input_run_loop_source_create_failed".to_owned();
        state.error(error.clone());
        let _ = ready.send(Err(error));
        return;
    }
    let dispatch_state = state.clone();
    let dispatch_app = app.clone();
    let dispatch = match thread::Builder::new()
        .name("wuwatappo-input-events".into())
        .spawn(move || dispatch_events(dispatch_app, dispatch_state, receiver))
    {
        Ok(thread) => thread,
        Err(error) => {
            unsafe {
                CFMachPortInvalidate(tap);
                CFRelease(source);
                CFRelease(tap);
            }
            let error = format!("input_dispatch_spawn_failed: {error}");
            state.error(error.clone());
            let _ = ready.send(Err(error));
            return;
        }
    };
    let run_loop = unsafe { CFRunLoopGetCurrent() };
    unsafe {
        CFRetain(run_loop);
        CFRunLoopAddSource(run_loop, source, kCFRunLoopCommonModes);
        CGEventTapEnable(tap, true);
    }
    let initialization = (|| -> Result<(), String> {
        *state
            .run_loop
            .lock()
            .map_err(|_| "input_run_loop_lock_poisoned")? = run_loop as usize;
        *state
            .event_tap
            .lock()
            .map_err(|_| "input_event_tap_lock_poisoned")? = tap as usize;
        if !unsafe { CGEventTapIsEnabled(tap) } {
            return Err("input_event_tap_enable_failed".into());
        }
        state.running.store(true, Ordering::Release);
        Ok(())
    })();
    if let Err(error) = &initial