//! Read-only GOP fold comparison against the live vault.
//!
//! Pulls 120 leftover JPEGs and encodes them twice in memory:
//!   A) per-app buckets, keyint=12  (previous default)
//!   B) wall-clock order, keyint=30 (current default)
//!
//! Does not write to the vault.
//!
//!   cargo run -p afterrayd --example compare-gop-fold

use afterray_codec::{Av1Encoder, GopFrameInput, Rav1eEncoder, jpeg_to_i420};
use afterray_protocol::{Moment, Request, Response};
use afterray_store::PackCandidate;
use std::collections::HashMap;
use std::io::{BufRead as _, Read as _, Write as _};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const SAMPLE: usize = 120;
const IDLE_GAP_MS: i64 = 30_000;

fn main() {
    let socket = socket_path();
    eprintln!("socket {}", socket.display());

    let now_ms = i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis(),
    )
    .unwrap();
    let moments: Vec<Moment> = rpc_json(
        &socket,
        Request::TimelineSince {
            since_ms: now_ms - 4 * 3_600_000,
        },
    );
    let mut moments = moments;
    let recent_stills = moments
        .iter()
        .filter(|moment| moment.image_artifact_id.is_some() && !is_loginwindow(moment))
        .count();
    if recent_stills < SAMPLE {
        eprintln!("recent window only has {recent_stills} JPEGs, falling back to full timeline");
        moments = rpc_json(&socket, Request::TimelineList);
    }
    let stills: Vec<&Moment> = moments
        .iter()
        .filter(|moment| moment.image_artifact_id.is_some() && !is_loginwindow(moment))
        .collect();
    eprintln!(
        "timeline {} moments, {} leftover JPEGs",
        moments.len(),
        stills.len()
    );
    assert!(
        stills.len() >= SAMPLE,
        "need {SAMPLE} leftover JPEGs, have {}",
        stills.len()
    );

    let window = pick_window(&stills);
    let span_min = (window[SAMPLE - 1].captured_at_ms - window[0].captured_at_ms) as f64 / 60_000.0;
    eprintln!(
        "window {}..{}  {:.1} min  {} app-changes  apps={:?}",
        fmt_ms(window[0].captured_at_ms),
        fmt_ms(window[SAMPLE - 1].captured_at_ms),
        span_min,
        app_changes(window),
        app_counts(window)
    );

    let scratch = std::env::temp_dir().join("afterray-gop-compare");
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).unwrap();

    eprintln!("reading {SAMPLE} JPEGs from daemon…");
    let mut frames = Vec::with_capacity(SAMPLE);
    let mut jpeg_bytes = 0_usize;
    let mut cursor = stills
        .iter()
        .position(|moment| moment.id == window[0].id)
        .unwrap_or(0);
    while frames.len() < SAMPLE {
        if cursor >= stills.len() {
            panic!(
                "ran out of leftover JPEGs after {} readable frames (packer may have dropped them)",
                frames.len()
            );
        }
        let moment = stills[cursor];
        cursor += 1;
        let Some(artifact_id) = moment.image_artifact_id.as_deref() else {
            continue;
        };
        let Some(jpeg) = read_artifact(&socket, artifact_id) else {
            eprintln!("  skip missing {artifact_id}");
            continue;
        };
        let (width, height) = afterray_store::jpeg_pixel_size(&jpeg)
            .map(|(width, height)| (width as u32, height as u32))
            .expect("jpeg size");
        let path = scratch.join(format!("{}.jpg", frames.len()));
        std::fs::write(&path, &jpeg).unwrap();
        jpeg_bytes += jpeg.len();
        frames.push(Prepared {
            candidate: PackCandidate {
                id: moment.id.clone(),
                captured_at_ms: moment.captured_at_ms,
                image_artifact_id: artifact_id.to_owned(),
                bundle_identifier: moment.bundle_identifier.clone(),
                application_name: moment.application_name.clone(),
                width,
                height,
            },
            jpeg_path: path,
        });
        if frames.len() % 20 == 0 {
            eprintln!("  fetched {}/{SAMPLE}  {}x{}", frames.len(), width, height);
        }
    }

    let encoder = Rav1eEncoder::default();
    let by_app = encode_strategy(
        "per-app keyint=12",
        &fold_by_app(candidates(&frames), 12),
        &frames,
        &encoder,
    );
    let by_time = encode_strategy(
        "timeline keyint=30",
        &afterray_store::fold_pack_runs(&candidates(&frames), 30),
        &frames,
        &encoder,
    );

    println!();
    println!(
        "{:<22} {:>6} {:>8} {:>8} {:>10} {:>8} {:>8} {:>7}",
        "strategy", "runs", "1-frame", "max", "ivf", "KiB/fr", "vs JPEG", "secs"
    );
    print_row(
        "JPEG baseline",
        0,
        0,
        0,
        jpeg_bytes,
        jpeg_bytes,
        SAMPLE,
        0.0,
    );
    print_row(
        &by_app.label,
        by_app.runs,
        by_app.singles,
        by_app.max_run,
        by_app.ivf_bytes,
        jpeg_bytes,
        SAMPLE,
        by_app.secs,
    );
    print_row(
        &by_time.label,
        by_time.runs,
        by_time.singles,
        by_time.max_run,
        by_time.ivf_bytes,
        jpeg_bytes,
        SAMPLE,
        by_time.secs,
    );
    println!(
        "\ntimeline/k30 is {:.1}× smaller than per-app/k12 on this window",
        by_app.ivf_bytes as f64 / by_time.ivf_bytes.max(1) as f64
    );
}

struct Prepared {
    candidate: PackCandidate,
    jpeg_path: PathBuf,
}

struct StrategyResult {
    label: String,
    runs: usize,
    singles: usize,
    max_run: usize,
    ivf_bytes: usize,
    secs: f64,
}

fn candidates(frames: &[Prepared]) -> Vec<PackCandidate> {
    frames.iter().map(|frame| frame.candidate.clone()).collect()
}

fn encode_strategy(
    label: &str,
    runs: &[Vec<PackCandidate>],
    frames: &[Prepared],
    encoder: &Rav1eEncoder,
) -> StrategyResult {
    let by_id: HashMap<&str, &Prepared> = frames
        .iter()
        .map(|frame| (frame.candidate.id.as_str(), frame))
        .collect();
    let singles = runs.iter().filter(|run| run.len() == 1).count();
    let max_run = runs.iter().map(Vec::len).max().unwrap_or(0);
    eprintln!(
        "{label}: {} runs ({}×1-frame, max {})",
        runs.len(),
        singles,
        max_run
    );
    let started = Instant::now();
    let mut ivf_bytes = 0_usize;
    for (index, run) in runs.iter().enumerate() {
        let decoded: Vec<_> = run
            .iter()
            .map(|candidate| {
                let frame = by_id[candidate.id.as_str()];
                let jpeg = std::fs::read(&frame.jpeg_path).expect("read scratch jpeg");
                jpeg_to_i420(&jpeg).expect("jpeg_to_i420")
            })
            .collect();
        let inputs: Vec<GopFrameInput<'_>> = run
            .iter()
            .zip(decoded.iter())
            .map(|(candidate, (width, height, yuv))| GopFrameInput {
                moment_id: candidate.id.as_str(),
                captured_at_ms: candidate.captured_at_ms,
                width: *width,
                height: *height,
                yuv: yuv.as_slice(),
            })
            .collect();
        let encoded = encoder
            .encode_closed_gop(&inputs)
            .unwrap_or_else(|error| panic!("{label} run {index}: {error}"));
        ivf_bytes += encoded.ivf.len();
        eprintln!(
            "  run {:>2}  {:>2} frames  {:>6.1} KiB  {}x{}",
            index + 1,
            run.len(),
            encoded.ivf.len() as f64 / 1024.0,
            encoded.width,
            encoded.height
        );
    }
    StrategyResult {
        label: label.to_owned(),
        runs: runs.len(),
        singles,
        max_run,
        ivf_bytes,
        secs: started.elapsed().as_secs_f64(),
    }
}

fn fold_by_app(candidates: Vec<PackCandidate>, keyint: u16) -> Vec<Vec<PackCandidate>> {
    let keyint = usize::from(keyint.max(1));
    type Key = (Option<String>, Option<String>, u32, u32);
    let mut buckets: HashMap<Key, Vec<PackCandidate>> = HashMap::new();
    let mut order: Vec<Key> = Vec::new();
    for candidate in candidates {
        let key = (
            candidate.bundle_identifier.clone(),
            candidate.application_name.clone(),
            candidate.width,
            candidate.height,
        );
        match buckets.get_mut(&key) {
            Some(bucket) => bucket.push(candidate),
            None => {
                order.push(key.clone());
                buckets.insert(key, vec![candidate]);
            }
        }
    }
    let mut runs: Vec<Vec<PackCandidate>> = Vec::new();
    for key in order {
        let Some(bucket) = buckets.remove(&key) else {
            continue;
        };
        let mut current: Vec<PackCandidate> = Vec::new();
        for candidate in bucket {
            if let Some(previous) = current.last()
                && candidate
                    .captured_at_ms
                    .saturating_sub(previous.captured_at_ms)
                    > IDLE_GAP_MS
            {
                runs.push(std::mem::take(&mut current));
            }
            current.push(candidate);
            if current.len() >= keyint {
                runs.push(std::mem::take(&mut current));
            }
        }
        if !current.is_empty() {
            runs.push(current);
        }
    }
    runs.sort_by(|left, right| {
        left.first()
            .map(|frame| (frame.captured_at_ms, frame.id.as_str()))
            .cmp(
                &right
                    .first()
                    .map(|frame| (frame.captured_at_ms, frame.id.as_str())),
            )
    });
    runs
}

fn pick_window<'a>(stills: &'a [&'a Moment]) -> &'a [&'a Moment] {
    let last = stills.len() - SAMPLE;
    let dense_limit = i64::try_from(SAMPLE).unwrap_or(120) * 12_000;
    let ranked: Vec<(i32, i64, usize)> = (0..=last)
        .map(|start| {
            let window = &stills[start..start + SAMPLE];
            let span = window[SAMPLE - 1].captured_at_ms - window[0].captured_at_ms;
            let switches = i32::try_from(app_changes(window)).unwrap_or(0);
            (switches, span, start)
        })
        .collect();
    let dense: Vec<_> = ranked
        .iter()
        .copied()
        .filter(|(_, span, _)| *span <= dense_limit)
        .collect();
    let pool = if dense.is_empty() { &ranked } else { &dense };
    let max_switch = pool.iter().map(|row| row.0).max().unwrap_or(0);
    let mut contenders: Vec<_> = pool
        .iter()
        .copied()
        .filter(|row| row.0 == max_switch)
        .collect();
    contenders.sort_by_key(|row| row.1);
    let mut rng = xorshift(seed());
    let pick = contenders[(rng() as usize) % contenders.len()];
    &stills[pick.2..pick.2 + SAMPLE]
}

fn app_changes(window: &[&Moment]) -> usize {
    window
        .windows(2)
        .filter(|pair| pair[0].application_name != pair[1].application_name)
        .count()
}

fn app_counts(window: &[&Moment]) -> Vec<(String, usize)> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for moment in window {
        *counts
            .entry(
                moment
                    .application_name
                    .clone()
                    .unwrap_or_else(|| "?".into()),
            )
            .or_insert(0) += 1;
    }
    let mut rows: Vec<_> = counts.into_iter().collect();
    rows.sort_by(|left, right| right.1.cmp(&left.1));
    rows
}

fn is_loginwindow(moment: &Moment) -> bool {
    moment
        .application_name
        .as_deref()
        .is_some_and(|name| name.eq_ignore_ascii_case("loginwindow"))
        || moment.bundle_identifier.as_deref().is_some_and(|bundle| {
            bundle.eq_ignore_ascii_case("com.apple.loginwindow") || bundle.contains("loginwindow")
        })
}

fn print_row(
    label: &str,
    runs: usize,
    singles: usize,
    max_run: usize,
    bytes: usize,
    jpeg_bytes: usize,
    frames: usize,
    secs: f64,
) {
    let kib = bytes as f64 / 1024.0 / frames as f64;
    let vs = if jpeg_bytes == 0 {
        "-".into()
    } else {
        format!("{:.1}%", bytes as f64 / jpeg_bytes as f64 * 100.0)
    };
    println!(
        "{:<22} {:>6} {:>8} {:>8} {:>7.1} MiB {:>8.1} {:>7} {:>6.1}",
        label,
        if runs == 0 {
            "-".into()
        } else {
            runs.to_string()
        },
        if runs == 0 {
            "-".into()
        } else {
            singles.to_string()
        },
        if max_run == 0 {
            "-".into()
        } else {
            max_run.to_string()
        },
        bytes as f64 / 1024.0 / 1024.0,
        kib,
        vs,
        secs
    );
}

fn socket_path() -> PathBuf {
    if let Ok(path) = std::env::var("AFTERRAY_SOCKET") {
        return PathBuf::from(path);
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../.afterray-dev/afterray.sock")
}

fn rpc_json<T: serde::de::DeserializeOwned>(socket: &Path, request: Request) -> T {
    let mut last = String::new();
    for attempt in 1..=4 {
        let mut stream = UnixStream::connect(socket).expect("connect daemon");
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(60)))
            .ok();
        let mut bytes = serde_json::to_vec(&request).unwrap();
        bytes.push(b'\n');
        stream.write_all(&bytes).unwrap();
        let mut line = String::new();
        match std::io::BufReader::new(stream).read_line(&mut line) {
            Ok(0) => last = "empty response".into(),
            Ok(_) => {
                let response: Response = serde_json::from_str(&line).unwrap_or_else(|error| {
                    panic!("bad json ({error}): {}", &line[..line.len().min(200)])
                });
                assert!(response.ok, "rpc failed: {:?}", response.error);
                return serde_json::from_value(response.data.unwrap()).unwrap();
            }
            Err(error) => last = error.to_string(),
        }
        eprintln!("rpc retry {attempt}: {last}");
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
    panic!("rpc failed after retries: {last}");
}

fn read_artifact(socket: &Path, artifact_id: &str) -> Option<Vec<u8>> {
    let mut stream = UnixStream::connect(socket).expect("connect daemon");
    let mut bytes = serde_json::to_vec(&Request::ReadArtifact {
        artifact_id: artifact_id.to_owned(),
    })
    .unwrap();
    bytes.push(b'\n');
    stream.write_all(&bytes).unwrap();
    let mut reader = std::io::BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let header: Response = serde_json::from_str(&line).unwrap();
    if !header.ok {
        return None;
    }
    let meta: afterray_protocol::ArtifactMeta =
        serde_json::from_value(header.data.unwrap()).unwrap();
    let mut body = vec![0_u8; usize::try_from(meta.byte_length).unwrap()];
    reader.read_exact(&mut body).unwrap();
    Some(body)
}

fn seed() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos() as u64
}

fn xorshift(seed: u64) -> impl FnMut() -> u64 {
    let mut state = seed | 1;
    move || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    }
}

fn fmt_ms(ms: i64) -> String {
    let seconds = ms / 1000;
    let datetime = chrono::DateTime::from_timestamp(seconds, 0).unwrap();
    datetime
        .with_timezone(&chrono::Local)
        .format("%m-%d %H:%M:%S")
        .to_string()
}
