use afterray_protocol::{ChatStreamEvent, Request};
use anyhow::Context;
use clap::Subcommand;
use std::io::Write as _;
use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

#[derive(Subcommand)]
pub enum ChatCommand {
    /// Ask and wait for the whole answer.
    Send {
        message: String,
        #[arg(long)]
        conversation: Option<String>,
    },
    /// Stream one turn as NDJSON events until `done` or `error`.
    Stream {
        message: String,
        #[arg(long)]
        conversation: Option<String>,
    },
    List,
    History {
        conversation_id: String,
    },
    Delete {
        conversation_id: String,
    },
}

pub async fn run(socket: &PathBuf, command: ChatCommand, json: bool) -> anyhow::Result<()> {
    match command {
        ChatCommand::Stream {
            message,
            conversation,
        } => run_stream(socket, conversation, message, json).await,
        other => run_once(socket, other, json).await,
    }
}

/// The request/response half of chat: everything except streaming, which
/// needs the connection held open across many lines.
async fn run_once(socket: &PathBuf, command: ChatCommand, json: bool) -> anyhow::Result<()> {
    let request = match command {
        ChatCommand::Send {
            message,
            conversation,
        } => Request::ChatSend {
            conversation_id: conversation,
            message,
        },
        ChatCommand::List => Request::ChatList,
        ChatCommand::History { conversation_id } => Request::ChatHistory { conversation_id },
        ChatCommand::Delete { conversation_id } => Request::ChatDelete { conversation_id },
        ChatCommand::Stream { .. } => unreachable!("stream is handled by run"),
    };
    let mut stream = UnixStream::connect(socket)
        .await
        .with_context(|| format!("connect to afterrayd at {}", socket.display()))?;
    let mut bytes = serde_json::to_vec(&request)?;
    bytes.push(b'\n');
    stream.write_all(&bytes).await?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).await?;
    let response: afterray_protocol::Response = serde_json::from_str(&line)?;
    if json {
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

async fn run_stream(
    socket: &PathBuf,
    conversation_id: Option<String>,
    message: String,
    json: bool,
) -> anyhow::Result<()> {
    let mut stream = UnixStream::connect(socket)
        .await
        .with_context(|| format!("connect to afterrayd at {}", socket.display()))?;
    let request = Request::ChatStream {
        conversation_id,
        message,
    };
    let mut bytes = serde_json::to_vec(&request)?;
    bytes.push(b'\n');
    stream.write_all(&bytes).await?;

    let mut lines = BufReader::new(stream).lines();
    let mut saw_done = false;
    let mut last_error = None;
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let event: ChatStreamEvent =
            serde_json::from_str(&line).with_context(|| format!("invalid stream event: {line}"))?;
        match &event {
            ChatStreamEvent::Done { .. } => saw_done = true,
            ChatStreamEvent::Error { message } => last_error = Some(message.clone()),
            _ => {}
        }
        print_event(&event, json)?;
        if matches!(
            event,
            ChatStreamEvent::Done { .. } | ChatStreamEvent::Error { .. }
        ) {
            break;
        }
    }
    if let Some(message) = last_error {
        anyhow::bail!(message);
    }
    if !saw_done {
        anyhow::bail!("chat stream ended before a done event");
    }
    Ok(())
}

fn print_event(event: &ChatStreamEvent, json: bool) -> anyhow::Result<()> {
    if json {
        println!("{}", serde_json::to_string(event)?);
        return Ok(());
    }
    match event {
        ChatStreamEvent::ToolCall { name, args } => {
            println!("tool_call {name} {args}");
        }
        ChatStreamEvent::ToolResult {
            name,
            chars,
            truncated,
            dropped,
        } => {
            let cut = if *truncated {
                format!(", ~{dropped} tokens cut")
            } else {
                String::new()
            };
            println!("tool_result {name} ({chars} chars{cut})");
        }
        ChatStreamEvent::Token { text } => {
            print!("{text}");
            std::io::stdout().flush()?;
        }
        ChatStreamEvent::Usage {
            prompt_tokens,
            window_tokens,
            round,
        } => {
            println!("usage round={round} {prompt_tokens}/{window_tokens} tokens");
        }
        // The row the answer is being written into. Nothing to print: the CLI
        // shows the text, and the id only matters to a client that reloads.
        ChatStreamEvent::Started { .. } => {}
        ChatStreamEvent::Progress {
            phase,
            reasoning_deltas,
            elapsed_ms,
            round,
        } => {
            // On one line, rewritten in place: this fires every 400 ms while a
            // turn is quiet, and scrolling the terminal would bury the answer.
            print!(
                "\r{phase} round={round} {reasoning_deltas} steps {}s   ",
                elapsed_ms / 1_000
            );
            std::io::stdout().flush()?;
        }
        ChatStreamEvent::Compaction {
            strategy,
            from_round,
            to_round,
            tokens_before,
            tokens_after,
        } => {
            println!(
                "compaction {strategy} rounds {from_round}..={to_round} \
                 {tokens_before} -> {tokens_after} tokens"
            );
        }
        ChatStreamEvent::Done {
            message_id,
            conversation_id,
        } => {
            println!();
            println!("done conversation={conversation_id} message={message_id}");
        }
        ChatStreamEvent::Error { message } => {
            if !message.ends_with('\n') {
                println!();
            }
            eprintln!("error {message}");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_request_shape_matches_protocol() {
        let json = serde_json::to_string(&Request::ChatStream {
            conversation_id: Some("c1".into()),
            message: "hi".into(),
        })
        .unwrap();
        assert!(json.contains(r#""type":"chat_stream""#));
        assert!(json.contains(r#""conversation_id":"c1""#));
    }
}
