use crate::engine::{Engine, OcrOptions, TextBlock};
use anyhow::{Context, Result, anyhow, bail, ensure};
use image::{DynamicImage, RgbImage};
use serde::{Deserialize, Serialize};
use std::{
    borrow::Cow,
    ffi::OsString,
    fmt,
    io::{self, BufReader, BufWriter, Read, Write},
    os::windows::{
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    ptr,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

pub const DEFAULT_IDLE_SECONDS: u64 = 90;
pub const MAX_IDLE_SECONDS: u64 = 3600;

const REQUEST_MAGIC: [u8; 4] = *b"WFOC";
const REPLY_MAGIC: [u8; 4] = *b"WFOR";
const MAX_HEADER_BYTES: usize = 1024 * 1024;
const MAX_PAYLOAD_BYTES: usize = 256 * 1024 * 1024;
const MAX_REPLY_BYTES: usize = 32 * 1024 * 1024;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug)]
pub struct LoadError(pub String);

impl fmt::Display for LoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for LoadError {}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum WorkerRequest {
    Recognize {
        id: u64,
        width: u32,
        height: u32,
        options: OcrOptions,
    },
    Shutdown {
        id: u64,
    },
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum WorkerReply {
    Boot {
        id: u64,
    },
    Blocks {
        id: u64,
        blocks: Vec<TextBlock>,
    },
    Ok {
        id: u64,
    },
    Error {
        id: u64,
        load_failed: bool,
        message: String,
    },
}

impl WorkerReply {
    fn id(&self) -> u64 {
        match self {
            Self::Boot { id }
            | Self::Blocks { id, .. }
            | Self::Ok { id }
            | Self::Error { id, .. } => *id,
        }
    }
}

pub fn trim_working_set() {
    unsafe {
        windows_sys::Win32::System::ProcessStatus::EmptyWorkingSet(
            windows_sys::Win32::System::Threading::GetCurrentProcess(),
        );
    }
}

fn write_request(
    writer: &mut impl Write,
    request: &WorkerRequest,
    payload: &[u8],
) -> Result<()> {
    let header = serde_json::to_vec(request).context("序列化 OCR 推理请求失败")?;
    ensure!(header.len() <= MAX_HEADER_BYTES, "OCR 推理请求头过大");
    ensure!(payload.len() <= MAX_PAYLOAD_BYTES, "OCR 图像数据过大");
    writer.write_all(&REQUEST_MAGIC)?;
    writer.write_all(&(header.len() as u32).to_le_bytes())?;
    writer.write_all(&(payload.len() as u32).to_le_bytes())?;
    writer.write_all(&header)?;
    if !payload.is_empty() {
        writer.write_all(payload)?;
    }
    writer.flush()?;
    Ok(())
}

fn read_request(reader: &mut impl Read) -> Result<Option<(WorkerRequest, Vec<u8>)>> {
    let mut magic = [0u8; 4];
    match reader.read_exact(&mut magic) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error.into()),
    }
    ensure!(magic == REQUEST_MAGIC, "无效的 OCR 推理请求帧头");
    let mut lengths = [0u8; 8];
    reader.read_exact(&mut lengths)?;
    let header_len = u32::from_le_bytes(lengths[0..4].try_into().unwrap()) as usize;
    let payload_len = u32::from_le_bytes(lengths[4..8].try_into().unwrap()) as usize;
    ensure!(
        header_len > 0 && header_len <= MAX_HEADER_BYTES,
        "OCR 推理请求头长度无效"
    );
    ensure!(payload_len <= MAX_PAYLOAD_BYTES, "OCR 推理请求数据过大");
    let mut header = vec![0u8; header_len];
    reader.read_exact(&mut header)?;
    let request: WorkerRequest =
        serde_json::from_slice(&header).context("解析 OCR 推理请求失败")?;
    let mut payload = vec![0u8; payload_len];
    if payload_len > 0 {
        reader.read_exact(&mut payload)?;
    }
    Ok(Some((request, payload)))
}

fn write_reply(writer: &mut impl Write, reply: &WorkerReply) -> Result<()> {
    let header = serde_json::to_vec(reply).context("序列化 OCR 推理响应失败")?;
    ensure!(header.len() <= MAX_REPLY_BYTES, "OCR 推理响应过大");
    writer.write_all(&REPLY_MAGIC)?;
    writer.write_all(&(header.len() as u32).to_le_bytes())?;
    writer.write_all(&header)?;
    writer.flush()?;
    Ok(())
}

fn read_reply(reader: &mut impl Read) -> Result<Option<WorkerReply>> {
    let mut magic = [0u8; 4];
    match reader.read_exact(&mut magic) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error.into()),
    }
    ensure!(magic == REPLY_MAGIC, "无效的 OCR 推理响应帧头");
    let mut len_bytes = [0u8; 4];
    reader.read_exact(&mut len_bytes)?;
    let header_len = u32::from_le_bytes(len_bytes) as usize;
    ensure!(
        header_len > 0 && header_len <= MAX_REPLY_BYTES,
        "OCR 推理响应长度无效"
    );
    let mut header = vec![0u8; header_len];
    reader.read_exact(&mut header)?;
    let reply: WorkerReply = serde_json::from_slice(&header).context("解析 OCR 推理响应失败")?;
    Ok(Some(reply))
}

pub fn run_worker(root: &Path) -> Result<()> {
    let stdin = io::stdin();
    let mut input = BufReader::new(stdin.lock());
    let stdout = io::stdout();
    let mut output = BufWriter::new(stdout.lock());
    write_reply(&mut output, &WorkerReply::Boot { id: 0 })?;

    let mut engine: Option<Engine> = None;
    while let Some((request, payload)) = read_request(&mut input)? {
        match request {
            WorkerRequest::Shutdown { id } => {
                engine = None;
                let _ = write_reply(&mut output, &WorkerReply::Ok { id });
                break;
            }
            WorkerRequest::Recognize {
                id,
                width,
                height,
                options,
            } => {
                let reply = handle_recognize(root, &mut engine, id, width, height, payload, &options);
                write_reply(&mut output, &reply)?;
            }
        }
    }
    drop(engine);
    Ok(())
}

fn handle_recognize(
    root: &Path,
    engine: &mut Option<Engine>,
    id: u64,
    width: u32,
    height: u32,
    payload: Vec<u8>,
    options: &OcrOptions,
) -> WorkerReply {
    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|pixels| pixels.checked_mul(3));
    if width == 0 || height == 0 || expected != Some(payload.len()) {
        return WorkerReply::Error {
            id,
            load_failed: false,
            message: "OCR 图像尺寸或像素数据无效".into(),
        };
    }
    let Some(rgb) = RgbImage::from_raw(width, height, payload) else {
        return WorkerReply::Error {
            id,
            load_failed: false,
            message: "无法重建 OCR 图像缓冲区".into(),
        };
    };
    if engine.is_none() {
        match Engine::new(root, options) {
            Ok(created) => *engine = Some(created),
            Err(error) => {
                return WorkerReply::Error {
                    id,
                    load_failed: true,
                    message: format!("{error:#}"),
                };
            }
        }
    }
    let image = DynamicImage::ImageRgb8(rgb);
    match engine.as_mut().unwrap().recognize(&image, options) {
        Ok(blocks) => WorkerReply::Blocks { id, blocks },
        Err(error) => WorkerReply::Error {
            id,
            load_failed: false,
            message: format!("{error:#}"),
        },
    }
}

fn attach_kill_on_close_job(child: &Child) -> Option<OwnedHandle> {
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
        SetInformationJobObject,
    };

    unsafe {
        let job = CreateJobObjectW(ptr::null(), ptr::null());
        if job.is_null() {
            return None;
        }
        let owned = OwnedHandle::from_raw_handle(job.cast());
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let ok = SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        );
        if ok == 0 {
            return None;
        }
        if AssignProcessToJobObject(job, child.as_raw_handle() as _) == 0 {
            return None;
        }
        Some(owned)
    }
}

struct WorkerConnection {
    child: Child,
    input: Option<BufWriter<ChildStdin>>,
    output: BufReader<ChildStdout>,
    _job: Option<OwnedHandle>,
}

impl WorkerConnection {
    fn spawn(exe: &Path, args: &[OsString]) -> Result<Self> {
        let mut child = Command::new(exe)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .with_context(|| format!("启动 OCR 推理子进程失败：{}", exe.display()))?;
        let job = attach_kill_on_close_job(&child);
        let input = BufWriter::new(child.stdin.take().context("无法连接 OCR 子进程输入管道")?);
        let mut output = BufReader::new(child.stdout.take().context("无法连接 OCR 子进程输出管道")?);
        let ready = read_reply(&mut output)?;
        match ready {
            Some(WorkerReply::Boot { id: 0 }) => Ok(Self {
                child,
                input: Some(input),
                output,
                _job: job,
            }),
            other => {
                let _ = child.kill();
                let _ = child.wait();
                bail!("OCR 推理子进程启动握手失败：{other:?}");
            }
        }
    }

    fn is_alive(&mut self) -> bool {
        self.child.try_wait().ok().flatten().is_none()
    }

    fn call(&mut self, request: &WorkerRequest, payload: &[u8]) -> Result<WorkerReply> {
        let input = self
            .input
            .as_mut()
            .context("OCR 推理子进程输入管道已关闭")?;
        write_request(input, request, payload).context("向 OCR 推理子进程发送请求失败")?;
        let reply = read_reply(&mut self.output)?
            .context("OCR 推理子进程意外退出")?;
        let expected_id = match request {
            WorkerRequest::Recognize { id, .. } | WorkerRequest::Shutdown { id } => *id,
        };
        ensure!(reply.id() == expected_id, "OCR 推理子进程响应序号不匹配");
        Ok(reply)
    }

    fn shutdown_gracefully(&mut self, id: u64) {
        if !self.is_alive() {
            return;
        }
        if let Some(input) = self.input.as_mut() {
            let _ = write_request(input, &WorkerRequest::Shutdown { id }, &[]);
        }
        // Closing stdin also guarantees the worker observes EOF even if the frame failed.
        self.input = None;
        let deadline = Instant::now() + SHUTDOWN_TIMEOUT;
        while Instant::now() < deadline {
            if self.child.try_wait().ok().flatten().is_some() {
                return;
            }
            thread::sleep(Duration::from_millis(10));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for WorkerConnection {
    fn drop(&mut self) {
        self.input = None;
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
    }
}

pub struct OcrWorker {
    root: PathBuf,
    exe_override: Option<PathBuf>,
    connection: Option<WorkerConnection>,
    next_id: u64,
    last_used: Option<Instant>,
}

impl OcrWorker {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            exe_override: None,
            connection: None,
            next_id: 1,
            last_used: None,
        }
    }

    #[cfg(test)]
    fn with_executable(root: PathBuf, exe: PathBuf) -> Self {
        Self {
            root,
            exe_override: Some(exe),
            connection: None,
            next_id: 1,
            last_used: None,
        }
    }

    pub fn is_running(&mut self) -> bool {
        if let Some(conn) = self.connection.as_mut() {
            if conn.is_alive() {
                return true;
            }
            self.connection = None;
            self.last_used = None;
        }
        false
    }

    pub fn last_used(&self) -> Option<Instant> {
        self.last_used
    }

    fn allocate_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1).max(1);
        id
    }

    fn ensure_started(&mut self) -> Result<()> {
        if self.is_running() {
            return Ok(());
        }
        let exe = match &self.exe_override {
            Some(path) => path.clone(),
            None => std::env::current_exe().context("无法获取当前程序路径")?,
        };
        let args = vec![
            OsString::from("--ocr-worker"),
            OsString::from("--models"),
            self.root.as_os_str().to_os_string(),
        ];
        let conn = WorkerConnection::spawn(&exe, &args)
            .map_err(|error| anyhow::Error::new(LoadError(format!("{error:#}"))))?;
        self.connection = Some(conn);
        Ok(())
    }

    pub fn recognize(
        &mut self,
        image: &DynamicImage,
        options: &OcrOptions,
    ) -> Result<Vec<TextBlock>> {
        ensure!(image.width() > 0 && image.height() > 0, "OCR 图像为空");
        let rgb = match image.as_rgb8() {
            Some(rgb) => Cow::Borrowed(rgb),
            None => Cow::Owned(image.to_rgb8()),
        };
        self.ensure_started()?;
        let id = self.allocate_id();
        let request = WorkerRequest::Recognize {
            id,
            width: rgb.width(),
            height: rgb.height(),
            options: options.clone(),
        };
        let reply = match self
            .connection
            .as_mut()
            .unwrap()
            .call(&request, rgb.as_raw())
        {
            Ok(reply) => reply,
            Err(error) => {
                self.connection = None;
                self.last_used = None;
                return Err(error);
            }
        };
        drop(rgb);
        match reply {
            WorkerReply::Blocks { blocks, .. } => {
                self.last_used = Some(Instant::now());
                Ok(blocks)
            }
            WorkerReply::Error {
                load_failed: true,
                message,
                ..
            } => {
                if self.last_used.is_none() {
                    self.shutdown();
                } else {
                    self.last_used = Some(Instant::now());
                }
                Err(anyhow::Error::new(LoadError(message)))
            }
            WorkerReply::Error {
                load_failed: false,
                message,
                ..
            } => {
                self.last_used = Some(Instant::now());
                Err(anyhow!("{message}"))
            }
            other => {
                self.connection = None;
                self.last_used = None;
                bail!("OCR 推理子进程返回了意外消息：{other:?}");
            }
        }
    }

    pub fn retire_idle(&mut self) -> bool {
        if self.shutdown() {
            trim_working_set();
            true
        } else {
            false
        }
    }

    pub fn shutdown(&mut self) -> bool {
        let Some(mut conn) = self.connection.take() else {
            self.last_used = None;
            return false;
        };
        let id = self.allocate_id();
        conn.shutdown_gracefully(id);
        drop(conn);
        self.last_used = None;
        true
    }
}

impl Drop for OcrWorker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

enum ServiceCommand {
    Recognize {
        image: DynamicImage,
        options: OcrOptions,
        reply: mpsc::Sender<Result<Vec<TextBlock>>>,
    },
    Stop,
}

#[derive(Clone)]
pub struct OcrClient {
    sender: mpsc::Sender<ServiceCommand>,
}

impl OcrClient {
    pub fn recognize(&self, image: &DynamicImage, options: &OcrOptions) -> Result<Vec<TextBlock>> {
        let (tx, rx) = mpsc::channel();
        self.sender
            .send(ServiceCommand::Recognize {
                image: image.clone(),
                options: options.clone(),
                reply: tx,
            })
            .context("OCR 调度服务已停止")?;
        rx.recv().context("OCR 调度服务未返回结果")?
    }
}

pub struct OcrService {
    client: OcrClient,
    thread: Option<thread::JoinHandle<()>>,
}

impl OcrService {
    pub fn start(root: PathBuf, idle_timeout: Duration) -> Result<Self> {
        let (sender, receiver) = mpsc::channel::<ServiceCommand>();
        let thread = thread::Builder::new()
            .name("ocr-dispatch".into())
            .spawn(move || {
                let mut worker = OcrWorker::new(root);
                loop {
                    let command = if worker.is_running() && !idle_timeout.is_zero() {
                        let remaining = worker
                            .last_used()
                            .map(|used| idle_timeout.saturating_sub(used.elapsed()))
                            .unwrap_or(idle_timeout);
                        match receiver.recv_timeout(remaining) {
                            Ok(command) => command,
                            Err(mpsc::RecvTimeoutError::Timeout) => {
                                worker.retire_idle();
                                continue;
                            }
                            Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        }
                    } else {
                        match receiver.recv() {
                            Ok(command) => command,
                            Err(_) => break,
                        }
                    };
                    match command {
                        ServiceCommand::Recognize {
                            image,
                            options,
                            reply,
                        } => {
                            let result = worker.recognize(&image, &options);
                            let _ = reply.send(result);
                        }
                        ServiceCommand::Stop => break,
                    }
                }
                worker.shutdown();
            })
            .context("无法启动 OCR 调度线程")?;
        Ok(Self {
            client: OcrClient { sender },
            thread: Some(thread),
        })
    }

    pub fn client(&self) -> OcrClient {
        self.client.clone()
    }
}

impl Drop for OcrService {
    fn drop(&mut self) {
        let _ = self.client.sender.send(ServiceCommand::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn request_and_reply_frames_roundtrip() {
        let options = OcrOptions {
            language: "v6_tiny".into(),
            threads: 4,
            classify: true,
            side_limit: 960,
            idle_seconds: 90,
        };
        let payload = vec![10u8, 20, 30, 40, 50, 60];
        let mut wire = Vec::new();
        write_request(
            &mut wire,
            &WorkerRequest::Recognize {
                id: 7,
                width: 2,
                height: 1,
                options: options.clone(),
            },
            &payload,
        )
        .unwrap();
        write_request(&mut wire, &WorkerRequest::Shutdown { id: 8 }, &[]).unwrap();

        let mut reader = Cursor::new(wire);
        let (first, bytes) = read_request(&mut reader).unwrap().unwrap();
        assert_eq!(bytes, payload);
        match first {
            WorkerRequest::Recognize {
                id,
                width,
                height,
                options: decoded,
            } => {
                assert_eq!(id, 7);
                assert_eq!((width, height), (2, 1));
                assert_eq!(decoded.language, options.language);
                assert_eq!(decoded.threads, options.threads);
                assert_eq!(decoded.classify, options.classify);
                assert_eq!(decoded.side_limit, options.side_limit);
                assert_eq!(decoded.idle_seconds, options.idle_seconds);
            }
            _ => panic!("expected recognize request"),
        }
        let (second, empty) = read_request(&mut reader).unwrap().unwrap();
        assert!(empty.is_empty());
        assert!(matches!(second, WorkerRequest::Shutdown { id: 8 }));
        assert!(read_request(&mut reader).unwrap().is_none());

        let mut reply_wire = Vec::new();
        write_reply(&mut reply_wire, &WorkerReply::Boot { id: 0 }).unwrap();
        write_reply(
            &mut reply_wire,
            &WorkerReply::Blocks {
                id: 7,
                blocks: vec![TextBlock {
                    text: "测试".into(),
                    score: 0.99,
                    points: [[1, 2], [3, 2], [3, 4], [1, 4]],
                }],
            },
        )
        .unwrap();
        write_reply(
            &mut reply_wire,
            &WorkerReply::Error {
                id: 8,
                load_failed: true,
                message: "缺少模型".into(),
            },
        )
        .unwrap();

        let mut reply_reader = Cursor::new(reply_wire);
        assert!(matches!(
            read_reply(&mut reply_reader).unwrap().unwrap(),
            WorkerReply::Boot { id: 0 }
        ));
        match read_reply(&mut reply_reader).unwrap().unwrap() {
            WorkerReply::Blocks { id, blocks } => {
                assert_eq!(id, 7);
                assert_eq!(blocks.len(), 1);
                assert_eq!(blocks[0].text, "测试");
            }
            _ => panic!("expected blocks reply"),
        }
        match read_reply(&mut reply_reader).unwrap().unwrap() {
            WorkerReply::Error {
                id,
                load_failed,
                message,
            } => {
                assert_eq!(id, 8);
                assert!(load_failed);
                assert_eq!(message, "缺少模型");
            }
            _ => panic!("expected error reply"),
        }
        assert!(read_reply(&mut reply_reader).unwrap().is_none());
    }

    #[test]
    fn invalid_image_payload_is_rejected_without_loading_engine() {
        let mut engine = None;
        let reply = handle_recognize(
            Path::new("."),
            &mut engine,
            3,
            4,
            4,
            vec![0u8; 5],
            &OcrOptions::default(),
        );
        assert!(engine.is_none());
        match reply {
            WorkerReply::Error {
                id,
                load_failed,
                message,
            } => {
                assert_eq!(id, 3);
                assert!(!load_failed);
                assert!(message.contains("无效"));
            }
            _ => panic!("expected invalid payload error"),
        }
    }

    #[test]
    fn worker_retire_idle_on_stopped_worker_is_noop() {
        let mut worker = OcrWorker::with_executable(PathBuf::from("models"), PathBuf::from("none"));
        assert!(!worker.is_running());
        assert!(worker.last_used().is_none());
        assert!(!worker.retire_idle());
    }

    #[test]
    fn trim_working_set_succeeds_safely() {
        trim_working_set();
    }
}
