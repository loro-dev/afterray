//! Builds T1 slot cards straight off a vault and prints the T2 prompt JSON.
//!
//! ```sh
//! cargo run -p afterray-store --example slot_cards -- \
//!     --data-dir .afterray/v0-data --at-ms 1786698000000 --slots 1
//! ```
//!
//! `--json` emits one machine-readable record per slot: `{card, system, user}`.

use afterray_store::{
    MacOsKeychainProvider, SLOT_DURATION_MS, T2_SYSTEM_PROMPT, Vault, VaultConfig,
    render_t2_prompt, slot_start_for,
};
use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut data_dir = PathBuf::from(".afterray/v0-data");
    let mut slots = 1_usize;
    let mut at_ms: Option<i64> = None;
    let mut as_json = false;
    let mut as_day = false;
    let mut language = "English".to_owned();

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--data-dir" => data_dir = PathBuf::from(args.next().unwrap_or_default()),
            "--slots" => slots = args.next().unwrap_or_default().parse().unwrap_or(1),
            "--at-ms" => at_ms = args.next().and_then(|value| value.parse().ok()),
            "--json" => as_json = true,
            "--day" => as_day = true,
            "--language" => language = args.next().unwrap_or_default(),
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

    let now_ms = at_ms.unwrap_or_else(|| {
        i64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_millis())
                .unwrap_or_default(),
        )
        .unwrap_or_default()
    });

    if as_day {
        let summary = vault.day_summary(now_ms, 10_000)?;
        println!("{}", serde_json::to_string_pretty(&summary)?);
        return Ok(());
    }

    let newest_start = slot_start_for(now_ms);
    let mut emitted = 0_usize;
    let mut index = 0_i64;
    while emitted < slots && index < 96 {
        let slot_start = newest_start - index * SLOT_DURATION_MS;
        index += 1;
        let mut card = vault.slot_card(slot_start, 10_000)?;
        if card.facts.moment_count == 0 {
            continue;
        }
        let background = vault.background_stats(&card).unwrap_or_default();
        afterray_store::attach_entity_candidates(&mut card, &background);
        let user = render_t2_prompt(&card, &[], &language, &background);
        if as_json {
            let record = serde_json::json!({
                "card": card,
                "system": T2_SYSTEM_PROMPT,
                "user": user,
            });
            println!("{}", serde_json::to_string(&record)?);
        } else {
            eprintln!(
                "── slot {} {}  state={:?}  moments={}  prompt_chars={}",
                card.local_day,
                card.slot_start_ms,
                card.state,
                card.facts.moment_count,
                user.chars().count(),
            );
            println!("{user}");
        }
        emitted += 1;
    }
    Ok(())
}
