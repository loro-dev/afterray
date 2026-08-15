mod chat;

use afterray_models::{download_packs, library_in, model_directory, specs_for_download_in};
use afterray_protocol::{Request, Response};
use anyhow::Context;
use clap::{Parser, Subcommand};
use std::{path::PathBuf, process::Command as ProcessCommand};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

#[derive(Parser)]
#[command(name = "afterray", version, about = "AfterRay V0 control client")]
struct Cli {
    #[arg(long, env = "AFTERRAY_SOCKET")]
    socket: Option<PathBuf>,
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Daemon {
        #[command(subcommand)]
        command: DaemonCommand,
    },
    Status,
    Record {
        #[command(subcommand)]
        command: RecordCommand,
    },
    Sessions {
        #[command(subcommand)]
        command: SessionsCommand,
    },
    Moments {
        session_id: String,
    },
    /// Fetch one moment by id, or the nearest one to a timestamp.
    Moment {
        #[arg(required_unless_present = "at_ms")]
        moment_id: Option<String>,
        /// Resolve the moment nearest this wall-clock instant instead.
        #[arg(long = "at-ms", conflicts_with = "moment_id")]
        at_ms: Option<i64>,
    },
    /// Deterministic T1 slot cards and the T2 prompt built from them.
    Slot {
        #[command(subcommand)]
        command: SlotCommand,
    },
    /// Write the captured frame nearest a timestamp to a file (for a vision model).
    Frame {
        #[arg(long = "at-ms")]
        at_ms: Option<i64>,
        #[arg(long, conflicts_with = "at_ms")]
        moment_id: Option<String>,
        /// Destination path. Defaults to `./frame-<moment_id>.jpg`.
        #[arg(long)]
        out: Option<PathBuf>,
    },
    Timeline {
        #[arg(long)]
        since_ms: Option<i64>,
    },
    Search {
        query: String,
        #[arg(long, default_value_t = 20)]
        limit: usize,
        #[arg(long = "from-ms")]
        from_ms: Option<i64>,
        #[arg(long = "to-ms")]
        to_ms: Option<i64>,
    },
    /// Read OCR / accessibility evidence for a moment.
    Evidence {
        #[command(subcommand)]
        command: EvidenceCommand,
    },
    Activity {
        #[arg(long)]
        from_ms: i64,
        #[arg(long)]
        to_ms: i64,
        #[arg(long, default_value_t = 100)]
        limit: usize,
    },
    Memories {
        #[arg(long)]
        from_ms: i64,
        #[arg(long)]
        to_ms: i64,
        #[arg(long, default_value_t = 40)]
        limit: usize,
    },
    History {
        #[command(subcommand)]
        command: HistoryCommand,
    },
    Favorite {
        #[command(subcommand)]
        command: FavoriteCommand,
    },
    /// Read or change daemon settings.
    Settings {
        /// Interface language (BCP-47 code, or `auto`).
        #[arg(long = "ui-language")]
        ui_language: Option<String>,
        /// Language the summarising agent writes cards in.
        #[arg(long = "summary-language")]
        summary_language: Option<String>,
    },
    Models,
    Download {
        #[arg(long)]
        pack: Option<String>,
        #[arg(long, env = "AFTERRAY_MODEL_DIR")]
        dir: Option<PathBuf>,
    },
    Jobs {
        #[command(subcommand)]
        command: JobsCommand,
    },
    Summarize {
        session_id: String,
    },
    Ask {
        question: String,
        #[arg(long = "from-ms")]
        from_ms: Option<i64>,
        #[arg(long = "to-ms")]
        to_ms: Option<i64>,
    },
    /// Multi-turn chat against the local vault.
    Chat {
        #[command(subcommand)]
        command: chat::ChatCommand,
    },
    Gop {
        segment_id: String,
    },
    Pack {
        #[command(subcommand)]
        command: PackCommand,
    },
}

#[derive(Subcommand)]
enum RecordCommand {
    Start,
    Stop,
}

#[derive(Subcommand)]
enum DaemonCommand {
    Start,
    Stop,
}

#[derive(Subcommand)]
enum SessionsCommand {
    List,
}

#[derive(Subcommand)]
enum FavoriteCommand {
    Add { moment_id: String },
    Remove { moment_id: String },
}

#[derive(Subcommand)]
enum JobsCommand {
    List,
    Retry { job_id: String },
}

#[derive(Subcommand)]
enum PackCommand {
    Status,
}

#[derive(Subcommand)]
enum SlotCommand {
    /// The T1 card: facts plus the retrieval map handed to a T2 agent.
    Card {
        #[arg(long = "at-ms")]
        at_ms: i64,
    },
    /// Run the T2 pass through the configured model and print the card.
    Summarize {
        #[arg(long = "at-ms")]
        at_ms: i64,
    },
    /// The rendered T2 prompt (system + user) for this slot.
    Prompt {
        #[arg(long = "at-ms")]
        at_ms: i64,
        /// Print only the user half, as plain text.
        #[arg(long)]
        user_only: bool,
    },
    /// The day panel payload: every occupied slot, T2 titles when they exist.
    Day {
        #[arg(long = "at-ms")]
        at_ms: i64,
    },
    /// Historical day summaries, newest first. Reuse `next_before_ms` from
    /// the previous JSON response to continue toward older history.
    History {
        #[arg(long = "before-ms")]
        before_ms: Option<i64>,
        #[arg(long, default_value_t = 7)]
        limit: usize,
    },
    /// Summarise every ready-but-untouched slot in the last N days. The daemon
    /// sweeps the last two on its own; this is for older history.
    Backfill {
        #[arg(long, default_value_t = 7)]
        days: i64,
    },
}

#[derive(Subcommand)]
enum EvidenceCommand {
    /// OCR text and bounding boxes for a moment, or the one nearest a timestamp.
    Ocr {
        #[arg(required_unless_present = "at_ms")]
        moment_id: Option<String>,
        #[arg(long = "at-ms", conflicts_with = "moment_id")]
        at_ms: Option<i64>,
    },
    /// Accessibility digest (default) or full tree JSON.
    Ax {
        #[arg(required_unless_present = "at_ms")]
        moment_id: Option<String>,
        #[arg(long = "at-ms", conflicts_with = "moment_id")]
        at_ms: Option<i64>,
        /// Include the full accessibility tree JSON (large).
        #[arg(long)]
        full: bool,
    },
}

#[derive(Subcommand)]
enum HistoryCommand {
    Clear {
        #[arg(long, value_enum)]
        scope: HistoryScopeArg,
    },
}

#[derive(Clone, clap::ValueEnum)]
enum HistoryScopeArg {
    LastHour,
    Today,
    All,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let socket = match cli.socket {
        Some(path) => path,
        None => afterray_protocol::socket::default_socket_path()
            .context("resolve the afterray daemon socket")?,
    };
    if let Command::Chat { command } = cli.command {
        return chat::run(&socket, command, cli.json).await;
    }
    let Some(request) = request_from_command(cli.command, &socket).await? else {
        return Ok(());
    };
    let response = send(&socket, &request).await?;
    if cli.json {
        println!("{}", serde_json::to_string_pretty(&response)?);
    } else if response.ok {
        println!("{}", serde_json::to_string_pretty(&response.data)?);
    } else {
        anyhow::bail!(
            response
                .error
                .unwrap_or_else(|| "unknown daemon error".to_owned())
        );
    }
    Ok(())
}

#[allow(clippy::too_many_lines)]
async fn request_from_command(
    command: Command,
    socket: &PathBuf,
) -> anyhow::Result<Option<Request>> {
    Ok(Some(match command {
        Command::Daemon {
            command: DaemonCommand::Start,
        } => {
            let status = ProcessCommand::new("afterrayd")
                .env("AFTERRAY_SOCKET", socket)
                .status()
                .context("start afterrayd; ensure it is installed or available on PATH")?;
            if !status.success() {
                anyhow::bail!("afterrayd exited with {status}");
            }
            return Ok(None);
        }
        Command::Daemon {
            command: DaemonCommand::Stop,
        } => Request::Shutdown,
        Command::Status => Request::Status,
        Command::Record {
            command: RecordCommand::Start,
        } => Request::RecordStart,
        Command::Record {
            command: RecordCommand::Stop,
        } => Request::RecordStop { reason: None },
        Command::Sessions {
            command: SessionsCommand::List,
        } => Request::SessionsList,
        Command::Moments { session_id } => Request::MomentsList { session_id },
        Command::Moment {
            moment_id: Some(moment_id),
            ..
        } => Request::MomentGet { moment_id },
        Command::Moment {
            at_ms: Some(at_ms), ..
        } => Request::MomentAt { at_ms },
        Command::Moment { .. } => anyhow::bail!("pass a moment id or --at-ms"),
        Command::Slot {
            command: SlotCommand::Card { at_ms },
        } => Request::SlotCard { at_ms },
        Command::Slot {
            command: SlotCommand::Summarize { at_ms },
        } => Request::SlotSummarize { at_ms },
        Command::Slot {
            command: SlotCommand::Day { at_ms },
        } => Request::DaySummary { day_ms: at_ms },
        Command::Slot {
            command: SlotCommand::History { before_ms, limit },
        } => Request::SummaryHistory { before_ms, limit },
        Command::Slot {
            command: SlotCommand::Backfill { days },
        } => Request::SlotBackfill { days },
        Command::Slot {
            command: SlotCommand::Prompt { at_ms, user_only },
        } => {
            if user_only {
                let response = send(socket, &Request::SlotPrompt { at_ms }).await?;
                let user = response
                    .data
                    .as_ref()
                    .and_then(|data| data.get("user"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                println!("{user}");
                return Ok(None);
            }
            Request::SlotPrompt { at_ms }
        }
        Command::Frame {
            at_ms,
            moment_id,
            out,
        } => {
            save_frame(socket, at_ms, moment_id, out).await?;
            return Ok(None);
        }
        Command::Timeline { since_ms: None } => Request::TimelineList,
        Command::Timeline {
            since_ms: Some(since_ms),
        } => Request::TimelineSince { since_ms },
        Command::Search {
            query,
            limit,
            from_ms,
            to_ms,
        } => Request::Search {
            query,
            limit,
            from_ms,
            to_ms,
        },
        Command::Evidence {
            command: EvidenceCommand::Ocr { moment_id, at_ms },
        } => Request::EvidenceOcr {
            moment_id: resolve_moment(socket, moment_id, at_ms).await?,
        },
        Command::Evidence {
            command:
                EvidenceCommand::Ax {
                    moment_id,
                    at_ms,
                    full,
                },
        } => Request::EvidenceAx {
            moment_id: resolve_moment(socket, moment_id, at_ms).await?,
            digest_only: !full,
        },
        Command::Activity {
            from_ms,
            to_ms,
            limit,
        } => Request::ActivitySpans {
            from_ms,
            to_ms,
            limit,
        },
        Command::Memories {
            from_ms,
            to_ms,
            limit,
        } => Request::MemoriesList {
            from_ms,
            to_ms,
            limit,
        },
        Command::History {
            command: HistoryCommand::Clear { scope },
        } => Request::ClearHistory {
            scope: match scope {
                HistoryScopeArg::LastHour => afterray_protocol::HistoryScope::LastHour,
                HistoryScopeArg::Today => afterray_protocol::HistoryScope::Today,
                HistoryScopeArg::All => afterray_protocol::HistoryScope::All,
            },
        },
        Command::Favorite {
            command: FavoriteCommand::Add { moment_id },
        } => Request::FavoriteSet {
            moment_id,
            favorite: true,
        },
        Command::Favorite {
            command: FavoriteCommand::Remove { moment_id },
        } => Request::FavoriteSet {
            moment_id,
            favorite: false,
        },
        Command::Download { pack, dir } => {
            run_local_download(pack, dir).await?;
            return Ok(None);
        }
        Command::Settings {
            ui_language: None,
            summary_language: None,
        } => Request::Settings,
        Command::Settings {
            ui_language,
            summary_language,
        } => Request::UpdateSettings {
            record_audio: None,
            ui_language,
            summary_language,
            storage_limit_bytes: None,
            excluded_bundle_ids: None,
            excluded_domains: None,
            llm_provider: None,
            llm_base_url: None,
            llm_model: None,
            llm_api_key: None,
        },
        Command::Models => Request::ModelsStatus,
        Command::Jobs {
            command: JobsCommand::List,
        } => Request::JobsList,
        Command::Jobs {
            command: JobsCommand::Retry { job_id },
        } => Request::JobRetry { job_id },
        Command::Summarize { session_id } => Request::Summarize { session_id },
        Command::Ask {
            question,
            from_ms,
            to_ms,
        } => Request::Ask {
            question,
            from_ms,
            to_ms,
        },
        Command::Chat { .. } => {
            anyhow::bail!("chat is handled before the one-line request path")
        }
        Command::Gop { segment_id } => Request::GopShow { segment_id },
        Command::Pack {
            command: PackCommand::Status,
        } => Request::PackStatus,
    }))
}

/// Accepts either an explicit moment id or a wall-clock instant.
async fn resolve_moment(
    socket: &PathBuf,
    moment_id: Option<String>,
    at_ms: Option<i64>,
) -> anyhow::Result<String> {
    if let Some(moment_id) = moment_id {
        return Ok(moment_id);
    }
    let at_ms = at_ms.context("pass a moment id or --at-ms")?;
    let response = send(socket, &Request::MomentAt { at_ms }).await?;
    if !response.ok {
        anyhow::bail!(
            response
                .error
                .unwrap_or_else(|| "could not resolve a moment".to_owned())
        );
    }
    response
        .data
        .as_ref()
        .and_then(|data| data.get("id"))
        .and_then(serde_json::Value::as_str)
        .map(ToOwned::to_owned)
        .context("daemon returned a moment without an id")
}

/// Reads an artifact off the framed response (JSON header line, then raw bytes)
/// and writes it to disk so a vision model can be pointed at the file.
async fn save_frame(
    socket: &PathBuf,
    at_ms: Option<i64>,
    moment_id: Option<String>,
    out: Option<PathBuf>,
) -> anyhow::Result<()> {
    let moment_id = resolve_moment(socket, moment_id, at_ms).await?;
    let moment = send(
        socket,
        &Request::MomentGet {
            moment_id: moment_id.clone(),
        },
    )
    .await?;
    let artifact_id = moment
        .data
        .as_ref()
        .and_then(|data| data.get("image_artifact_id"))
        .and_then(serde_json::Value::as_str)
        .context("this moment has no stored image")?
        .to_owned();

    let mut stream = UnixStream::connect(socket)
        .await
        .with_context(|| format!("connect to afterrayd at {}", socket.display()))?;
    let mut bytes = serde_json::to_vec(&Request::ReadArtifact {
        artifact_id: artifact_id.clone(),
    })?;
    bytes.push(b'\n');
    stream.write_all(&bytes).await?;

    let mut reader = BufReader::new(stream);
    let mut header_line = String::new();
    reader.read_line(&mut header_line).await?;
    let header: Response = serde_json::from_str(&header_line)?;
    if !header.ok {
        anyhow::bail!(
            header
                .error
                .unwrap_or_else(|| "artifact read failed".to_owned())
        );
    }
    let byte_length = header
        .data
        .as_ref()
        .and_then(|data| data.get("byte_length"))
        .and_then(serde_json::Value::as_u64)
        .context("artifact header had no byte_length")?;
    let content_type = header
        .data
        .as_ref()
        .and_then(|data| data.get("content_type"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("image/jpeg")
        .to_owned();

    let mut payload = vec![0_u8; usize::try_from(byte_length)?];
    tokio::io::AsyncReadExt::read_exact(&mut reader, &mut payload).await?;

    let extension = if content_type.contains("png") {
        "png"
    } else {
        "jpg"
    };
    let path = out.unwrap_or_else(|| PathBuf::from(format!("frame-{moment_id}.{extension}")));
    tokio::fs::write(&path, &payload).await?;
    println!(
        "{}",
        serde_json::json!({
            "moment_id": moment_id,
            "artifact_id": artifact_id,
            "content_type": content_type,
            "bytes": payload.len(),
            "path": path.display().to_string(),
        })
    );
    Ok(())
}

async fn run_local_download(pack: Option<String>, dir: Option<PathBuf>) -> anyhow::Result<()> {
    let directory = dir.unwrap_or_else(model_directory);
    let packs = specs_for_download_in(&directory, pack.as_deref()).map_err(anyhow::Error::msg)?;
    if packs.is_empty() {
        println!("{}", serde_json::to_string_pretty(&library_in(&directory))?);
        return Ok(());
    }
    download_packs(&packs, |spec, progress| {
        if let Some(percent) = progress.percent() {
            eprintln!("Downloading {} · {percent}%", spec.name);
        } else {
            eprintln!(
                "Downloading {} ({}/{} files)",
                spec.name, progress.completed_files, progress.total_files
            );
        }
    })
    .await?;
    println!("{}", serde_json::to_string_pretty(&library_in(&directory))?);
    Ok(())
}

async fn send(socket: &PathBuf, request: &Request) -> anyhow::Result<Response> {
    let mut stream = UnixStream::connect(socket)
        .await
        .with_context(|| format!("connect to afterrayd at {}", socket.display()))?;
    let mut bytes = serde_json::to_vec(request)?;
    bytes.push(b'\n');
    stream.write_all(&bytes).await?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).await?;
    Ok(serde_json::from_str(&line)?)
}
