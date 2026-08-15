//! Runs the T2 pass over real slots through the production inference path.
//!
//! Builds the T1 card straight off a vault, renders the prompt, and submits
//! it through `ModelQueue` + `LlmRouterAdapter` — the same harness the daemon
//! uses — so switching `--provider` exercises a local Ollama or any
//! OpenAI-compatible endpoint without touching a running daemon or the
//! user's capture session.
//!
//! ```sh
//! cargo run -p afterrayd --example t2_eval -- \
//!     --at-ms 1786698000000 --provider ollama --model qwen3.6:latest
//! ```

use afterray_models::{
    LlmRouterAdapter, LlmRuntimeConfig, ModelAdapter, ModelInput, ModelOutput, ModelQueue,
    QueueConfig,
};
use afterray_protocol::LlmProvider;
use afterray_store::{
    MacOsKeychainProvider, SLOT_DURATION_MS, T2_SYSTEM_PROMPT, Vault, VaultConfig,
    render_t2_prompt, slot_start_for,
};
use std::{path::PathBuf, sync::Arc};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut data_dir = PathBuf::from(".afterray/v0-data");
    let mut at_ms: Option<i64> = None;
    let mut slots = 1_usize;
    let mut provider = LlmProvider::Ollama;
    let mut model = "qwen3.6:latest".to_owned();
    let mut base_url = String::new();
    let mut show_raw = false;
    let mut language = "English".to_owned();

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data-dir" => data_dir = PathBuf::from(args.next().unwrap_or_default()),
            "--at-ms" => at_ms = args.next().and_then(|value| value.parse().ok()),
            "--slots" => slots = args.next().unwrap_or_default().parse().unwrap_or(1),
            "--model" => model = args.next().unwrap_or_default(),
            "--base-url" => base_url = args.next().unwrap_or_default(),
            "--raw" => show_raw = true,
            "--language" => language = args.next().unwrap_or_default(),
            "--provider" => {
                provider = args
                    .next()
                    .and_then(|value| LlmProvider::parse(&value))
                    .unwrap_or(LlmProvider::Ollama);
            }
            other => eprintln!("ignoring unknown argument {other}"),
        }
    }

    let vault = Vault::open(
        VaultConfig {
            data_dir,
            ..VaultConfig::default()
        },
        &MacOsKeychainProvider,
    )?;

    let config = Arc::new(std::sync::Mutex::new(LlmRuntimeConfig {
        provider,
        base_url,
        model: model.clone(),
        api_key: None,
        context_tokens: None,
    }));
    let adapters: Vec<Arc<dyn ModelAdapter>> =
        vec![Arc::new(LlmRouterAdapter::new(Arc::clone(&config)))];
    let queue = ModelQueue::new(adapters, QueueConfig::default())?;

    let now_ms = at_ms.unwrap_or_else(|| {
        i64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_millis())
                .unwrap_or_default(),
        )
        .unwrap_or_default()
    });

    let newest = slot_start_for(now_ms);
    let mut done = 0_usize;
    let mut index = 0_i64;
    while done < slots && index < 96 {
        let slot_start = newest - index * SLOT_DURATION_MS;
        index += 1;
        let mut card = vault.slot_card(slot_start, 10_000)?;
        if card.facts.moment_count == 0 {
            continue;
        }
        let background = vault.background_stats(&card).unwrap_or_default();
        afterray_store::attach_entity_candidates(&mut card, &background);
        let user = render_t2_prompt(&card, &[], &language, &background);
        println!("════════════════════════════════════════════════════");
        println!(
            "slot {} {} · {} moments · prompt {} chars · provider {:?} · model {model} · lang {language}",
            card.local_day,
            card.slot_start_ms,
            card.facts.moment_count,
            user.chars().count(),
            provider,
        );

        let started = std::time::Instant::now();
        let job = queue
            .submit(ModelInput::Llm {
                messages: Vec::new(),
                prompt: user.clone(),
                system: Some(T2_SYSTEM_PROMPT.to_owned()),
            })
            .await?;
        let snapshot = queue.wait(&job).await?;
        let elapsed = started.elapsed();

        let raw = match snapshot.output {
            Some(ModelOutput::Llm { text }) => text,
            _ => {
                println!(
                    "  FAILED after {:.1}s: {}",
                    elapsed.as_secs_f64(),
                    snapshot.last_error.unwrap_or_else(|| "no output".into())
                );
                done += 1;
                continue;
            }
        };

        println!(
            "  {:.1}s · {} output chars · adapter {}",
            elapsed.as_secs_f64(),
            raw.chars().count(),
            snapshot.adapter
        );
        if show_raw {
            println!("  ── raw ──\n{raw}\n  ── end raw ──");
        }
        match extract_json_object(&raw).and_then(|slice| serde_json::from_str(slice).ok()) {
            Some(serde_json::Value::Object(card_json)) => {
                println!("  parsed ✓");
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::Value::Object(card_json))?
                );
            }
            _ => println!("  parsed ✗ — model did not emit a JSON object:\n{raw}"),
        }
        done += 1;
    }
    Ok(())
}

/// First balanced `{…}` block, so prose or a fenced block around the JSON
/// still parses.
fn extract_json_object(text: &str) -> Option<&str> {
    let start = text.find('{')?;
    let mut depth = 0_i32;
    let mut in_string = false;
    let mut escaped = false;
    for (index, character) in text[start..].char_indices() {
        if in_string {
            match character {
                _ if escaped => escaped = false,
                '\\' => escaped = true,
                '"' => in_string = false,
                _ => {}
            }
            continue;
        }
        match character {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(&text[start..=start + index]);
                }
            }
            _ => {}
        }
    }
    None
}
