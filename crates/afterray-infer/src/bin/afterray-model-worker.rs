use afterray_infer::{InferConfig, execute};
use afterray_models::{ModelOutput, WORKER_PROTOCOL_VERSION, WorkerRequest, WorkerResponse};
use std::io::{self, Read, Write};

fn main() {
    match run() {
        Ok(()) => {}
        Err(error) => {
            let _ = writeln!(io::stderr(), "{error}");
            std::process::exit(1);
        }
    }
}

fn run() -> Result<(), String> {
    let mut stdin = String::new();
    io::stdin()
        .read_to_string(&mut stdin)
        .map_err(|error| error.to_string())?;
    let request: WorkerRequest =
        serde_json::from_str(stdin.trim()).map_err(|error| error.to_string())?;
    if request.protocol_version != WORKER_PROTOCOL_VERSION {
        return write_response(&WorkerResponse {
            protocol_version: WORKER_PROTOCOL_VERSION,
            output: None,
            error: Some(format!(
                "unsupported worker protocol {}",
                request.protocol_version
            )),
            retryable: false,
        });
    }
    let config = InferConfig::from_env();
    let started = std::time::Instant::now();
    match execute(&config, &request.input) {
        Ok(output) => {
            let elapsed_ms = started.elapsed().as_millis();
            let _ = writeln!(
                io::stderr(),
                "worker {} finished in {elapsed_ms}ms ({})",
                request.capability.as_label(),
                output_preview(&output)
            );
            write_response(&WorkerResponse {
                protocol_version: WORKER_PROTOCOL_VERSION,
                output: Some(output),
                error: None,
                retryable: false,
            })
        }
        Err(error) => {
            let elapsed_ms = started.elapsed().as_millis();
            let _ = writeln!(
                io::stderr(),
                "worker {} failed after {elapsed_ms}ms: {error}",
                request.capability.as_label()
            );
            write_response(&WorkerResponse {
                protocol_version: WORKER_PROTOCOL_VERSION,
                output: None,
                error: Some(error.to_string()),
                retryable: error.retryable(),
            })
        }
    }
}

fn output_preview(output: &ModelOutput) -> String {
    match output {
        ModelOutput::Ocr { text, regions } => {
            format!("{} chars, {} regions", text.chars().count(), regions.len())
        }
        ModelOutput::Llm { text, .. } => format!("{} chars", text.chars().count()),
        ModelOutput::Asr { text, language } => match language {
            Some(language) if !language.is_empty() => {
                format!("{language}, {} chars", text.chars().count())
            }
            _ => format!("{} chars", text.chars().count()),
        },
        ModelOutput::Alignment { cues } => format!("{} aligned cues", cues.len()),
        ModelOutput::Embedding { vector } => format!("{} dims", vector.len()),
    }
}

fn write_response(response: &WorkerResponse) -> Result<(), String> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, response).map_err(|error| error.to_string())?;
    stdout.write_all(b"\n").map_err(|error| error.to_string())?;
    Ok(())
}
