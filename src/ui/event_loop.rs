use std::cell::Cell;
use std::time::Instant;

use anyhow::{Context, Result, ensure};
use eframe::{AppCreator, EframeWinitApplication, NativeOptions, UserEvent};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use winit::{
    application::ApplicationHandler,
    event::{DeviceEvent, DeviceId, StartCause, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    window::WindowId,
};

pub(super) fn run(title: &str, options: NativeOptions, create: AppCreator<'_>) -> Result<()> {
    let event_loop = EventLoop::<UserEvent>::with_user_event()
        .build()
        .context("无法创建窗口事件循环")?;
    let created = Cell::new(false);
    let window = Cell::new(None);
    let app = eframe::create_native(
        title,
        options,
        Box::new(|context| {
            if let Ok(handle) = context.window_handle()
                && let RawWindowHandle::Win32(handle) = handle.as_raw()
            {
                window.set(Some(handle.hwnd.get()));
            }
            let app = create(context)?;
            created.set(true);
            Ok(app)
        }),
        &event_loop,
    );
    event_loop
        .run_app(&mut WindowsEventLoop {
            app,
            window: &window,
            repaint_at: None,
        })
        .context("窗口事件循环失败")?;
    ensure!(created.get(), "无法初始化文字识别主窗口");
    Ok(())
}

struct WindowsEventLoop<'a> {
    app: EframeWinitApplication<'a>,
    window: &'a Cell<Option<isize>>,
    repaint_at: Option<Instant>,
}

impl ApplicationHandler<UserEvent> for WindowsEventLoop<'_> {
    fn new_events(&mut self, event_loop: &ActiveEventLoop, cause: StartCause) {
        self.app.new_events(event_loop, cause);
    }

    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        self.app.resumed(event_loop);
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: UserEvent) {
        if let UserEvent::RequestRepaint {
            viewport_id, when, ..
        } = &event
            && *viewport_id == eframe::egui::ViewportId::ROOT
        {
            self.repaint_at = Some(self.repaint_at.map_or(*when, |pending| pending.min(*when)));
        }
        self.app.user_event(event_loop, event);
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, id: WindowId, event: WindowEvent) {
        if matches!(event, WindowEvent::RedrawRequested)
            && self
                .window
                .get()
                .is_some_and(|handle| u64::from(id) == handle as u64)
        {
            self.repaint_at = None;
        }
        self.app.window_event(event_loop, id, event);
    }

    fn device_event(&mut self, event_loop: &ActiveEventLoop, id: DeviceId, event: DeviceEvent) {
        self.app.device_event(event_loop, id, event);
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        self.app.about_to_wait(event_loop);
        // Win32 does not dispatch WM_PAINT for an invisible window. Service
        // due updates without showing the HWND, including worker completion,
        // clipboard writes, reload, explicit show and exit commands.
        if let Some(handle) = self.window.get()
            && unsafe {
                use windows_sys::Win32::UI::WindowsAndMessaging::{IsIconic, IsWindowVisible};
                let hwnd = handle as windows_sys::Win32::Foundation::HWND;
                IsWindowVisible(hwnd) == 0 || IsIconic(hwnd) != 0
            }
            && let Some(when) = self.repaint_at
        {
            if when <= Instant::now() {
                self.repaint_at = None;
                self.app.window_event(
                    event_loop,
                    WindowId::from(handle as u64),
                    WindowEvent::RedrawRequested,
                );
            } else {
                let deadline = match event_loop.control_flow() {
                    ControlFlow::WaitUntil(deadline) => deadline.min(when),
                    _ => when,
                };
                event_loop.set_control_flow(ControlFlow::WaitUntil(deadline));
            }
        }
        // eframe 0.33 can leave Poll set when a hidden HWND never delivers
        // the requested redraw. Native messages can wake Wait on their own.
        if event_loop.control_flow() == ControlFlow::Poll {
            event_loop.set_control_flow(ControlFlow::Wait);
        }
    }

    fn suspended(&mut self, event_loop: &ActiveEventLoop) {
        self.app.suspended(event_loop);
    }

    fn exiting(&mut self, event_loop: &ActiveEventLoop) {
        self.app.exiting(event_loop);
    }

    fn memory_warning(&mut self, event_loop: &ActiveEventLoop) {
        self.app.memory_warning(event_loop);
    }
}
