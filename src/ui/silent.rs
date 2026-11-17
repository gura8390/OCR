use super::Settings;
use crate::jobs::{self, Kind, ResultItem, Source, Update};
use image::DynamicImage;
use std::{
    sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};

/// Keeps native-only tray captures on the same worker later used by the GUI.
/// No renderer or window is needed to receive results and update the clipboard.
#[derive(Default)]
pub(super) struct State {
    pub(super) history: Vec<ResultItem>,
    pub(super) status: Option<String>,
    pub(super) error: Option<String>,
    pub(super) busy: bool,
    pub(super) pending: Option<DynamicImage>,
    pub(super) control: Arc<AtomicU8>,
}

impl State {
    pub(super) fn capture(
        &mut self,
        image: DynamicImage,
        settings: &Settings,
        requests: &mpsc::Sender<jobs::Request>,
    ) {
        if self.busy {
            self.pending = Some(image);
            self.status = Some("已保留最新截图，当前任务结束后识别".into());
            return;
        }

        self.error = None;
        self.control.store(0, Ordering::Relaxed);
        let request = jobs::Request {
            inputs: vec![Source::Memory("屏幕选区".into(), image)],
            options: settings.job_options(),
            kind: Kind::Capture,
            pdf: None,
            control: self.control.clone(),
        };
        if requests.send(request).is_ok() {
            self.busy = true;
            self.status = Some("正在准备识别…".into());
        } else {
            self.error = Some("识别线程已退出，请重启应用".into());
            self.status = Some("识别失败".into());
        }
    }

    pub(super) fn update(
        &mut self,
        update: Update,
        settings: &Settings,
        requests: &mpsc::Sender<jobs::Request>,
    ) {
        match update {
            Update::Progress(status) => self.status = Some(status),
            Update::Error(error) => self.error = Some(error),
            Update::Result(item) => {
                let empty = item.text.trim().is_empty();
                self.status = Some(format!(
                    "{} · {:.0} 毫秒",
                    if empty {
                        "未识别到内容"
                    } else {
                        "识别完成"
                    },
                    item.elapsed.as_secs_f64() * 1000.0
                ));
                if settings.auto_copy && !empty {
                    match copy_text(&item.text) {
                        Ok(()) => {
                            self.status = Some(format!(
                                "识别完成，结果已复制 · {:.0} 毫秒",
                                item.elapsed.as_secs_f64() * 1000.0
                            ));
                        }
                        Err(error) => self.error = Some(error),
                    }
                }

                // Match the screenshot page: retain all text history, but keep
                // image previews for only the newest six completed captures.
                if self.history.len() >= 6 {
                    let older = self.history.len() - 6;
                    self.history[older].preview = None;
                }
                self.history.push(item);
            }
            Update::Done => {
                self.busy = false;
                if let Some(image) = self.pending.take() {
                    self.capture(image, settings, requests);
                }
            }
        }
    }
}

/// Native clipboard writes also work when no eframe frame is being rendered.
pub(super) fn copy_text(text: &str) -> Result<(), String> {
    let mut last_error = None;
    for attempt in 0..5 {
        match arboard::Clipboard::new().and_then(|mut clipboard| clipboard.set_text(text)) {
            Ok(()) => return Ok(()),
            Err(error) => last_error = Some(error),
        }
        if attempt < 4 {
            thread::sleep(Duration::from_millis(20));
        }
    }
    Err(format!(
        "识别完成，但无法复制结果到剪贴板，请打开主窗口复制 · {}",
        last_error.expect("clipboard attempts always set an error")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgb, RgbImage};

    fn image(marker: u8) -> DynamicImage {
        RgbImage::from_pixel(2, 1, Rgb([marker, 0, 0])).into()
    }

    fn result(text: &str, marker: u8) -> ResultItem {
        ResultItem {
            title: "屏幕选区".into(),
            text: text.into(),
            blocks: Vec::new(),
            preview: Some(image(marker)),
            image_size: [2, 1],
            elapsed: Duration::from_millis(12),
        }
    }

    fn marker(request: &jobs::Request) -> u8 {
        assert_eq!(request.inputs.len(), 1);
        let Source::Memory(title, image) = &request.inputs[0] else {
            panic!("a screen selection must remain an in-memory source");
        };
        assert_eq!(title, "屏幕选区");
        assert_eq!([image.width(), image.height()], [2, 1]);
        image.to_rgb8().get_pixel(0, 0).0[0]
    }

    #[test]
    fn capture_submits_current_options_and_shared_cancellation_control() {
        let mut settings = Settings::default();
        settings.ocr.language = "en".into();
        settings.ocr.threads = 7;
        settings.ocr.classify = true;
        settings.ocr.side_limit = 1536;
        settings.parser = "single_para".into();
        settings.ignore = vec![[[1, 2], [3, 2], [3, 4], [1, 4]]];
        settings.dpi = 240;
        settings.native_text = false;
        let (requests, work) = mpsc::channel();
        let mut state = State::default();
        state.control.store(2, Ordering::Relaxed);
        state.error = Some("旧错误".into());

        state.capture(image(1), &settings, &requests);

        let request = work
            .try_recv()
            .expect("capture must submit a worker request");
        assert_eq!(marker(&request), 1);
        assert_eq!(request.kind, Kind::Capture);
        assert!(request.pdf.is_none());
        assert_eq!(request.options.ocr.language, "en");
        assert_eq!(request.options.ocr.threads, 7);
        assert!(request.options.ocr.classify);
        assert_eq!(request.options.ocr.side_limit, 1536);
        assert_eq!(request.options.parser, "single_para");
        assert_eq!(request.options.ignore, settings.ignore);
        assert_eq!(request.options.dpi, 240);
        assert!(!request.options.native_text);
        assert!(request.options.password.is_empty());
        assert!(Arc::ptr_eq(&request.control, &state.control));
        assert_eq!(request.control.load(Ordering::Relaxed), 0);
        assert!(state.busy);
        assert!(state.error.is_none());
        assert!(work.try_recv().is_err());
    }

    #[test]
    fn busy_capture_keeps_only_latest_image_and_submits_it_after_done() {
        let mut settings = Settings::default();
        let (requests, work) = mpsc::channel();
        let mut state = State::default();
        state.capture(image(1), &settings, &requests);
        assert_eq!(marker(&work.try_recv().unwrap()), 1);

        state.capture(image(2), &settings, &requests);
        state.capture(image(3), &settings, &requests);
        assert!(work.try_recv().is_err());
        assert!(state.busy);
        settings.ocr.threads = 9;
        state.update(Update::Done, &settings, &requests);

        let request = work
            .try_recv()
            .expect("done must submit the newest pending image");
        assert_eq!(marker(&request), 3);
        assert_eq!(request.options.ocr.threads, 9);
        assert!(state.busy);
        assert!(state.pending.is_none());
        assert!(work.try_recv().is_err());
        state.update(Update::Done, &settings, &requests);
        assert!(!state.busy);
        assert!(work.try_recv().is_err());
    }

    #[test]
    fn disconnected_worker_reports_failure_without_leaving_capture_busy() {
        let settings = Settings::default();
        let (requests, work) = mpsc::channel();
        drop(work);
        let mut state = State::default();

        state.capture(image(1), &settings, &requests);

        assert!(!state.busy);
        assert!(state.pending.is_none());
        assert_eq!(state.status.as_deref(), Some("识别失败"));
        assert_eq!(state.error.as_deref(), Some("识别线程已退出，请重启应用"));
        assert!(state.history.is_empty());
    }

    #[test]
    fn results_keep_text_history_and_limit_previews_without_copying() {
        let mut settings = Settings::default();
        settings.auto_copy = false;
        let (requests, work) = mpsc::channel();
        let mut state = State::default();
        for index in 0..8 {
            let text = if index == 7 {
                "  \n".into()
            } else {
                format!("结果{index}")
            };
            state.update(Update::Result(result(&text, index)), &settings, &requests);
        }

        assert_eq!(state.history.len(), 8);
        assert_eq!(state.history[0].text, "结果0");
        assert_eq!(state.history[6].text, "结果6");
        assert_eq!(state.history[7].text, "  \n");
        assert!(state.history[..2].iter().all(|item| item.preview.is_none()));
        assert!(state.history[2..].iter().all(|item| item.preview.is_some()));
        assert_eq!(state.status.as_deref(), Some("未识别到内容 · 12 毫秒"));
        assert!(state.error.is_none());
        assert!(work.try_recv().is_err());
    }

    #[test]
    fn empty_auto_copy_result_stays_available_without_touching_clipboard() {
        let settings = Settings::default();
        let (requests, _) = mpsc::channel();
        let mut state = State::default();

        state.update(Update::Result(result("", 1)), &settings, &requests);

        assert_eq!(state.history.len(), 1);
        assert!(state.history[0].text.is_empty());
        assert_eq!(state.status.as_deref(), Some("未识别到内容 · 12 毫秒"));
        assert!(state.error.is_none());
    }
}
