//! Prints what the background-work probes see right now.
//!
//! When T2 summaries are not appearing, this answers the first question —
//! whether the machine actually looks idle and powered to the daemon, or
//! whether a probe is reading wrong. Compare against `pmset -g batt` and
//! `uptime`.
//!
//! `cargo run -p afterray-platform-macos --example power-probe`

fn main() {
    println!(
        "on AC power     : {}",
        afterray_platform_macos::on_ac_power()
    );
    match afterray_platform_macos::battery_fraction() {
        Some(fraction) => println!("battery         : {:.0}%", fraction * 100.0),
        None => println!("battery         : none (desktop)"),
    }
    println!(
        "idle            : {:.0}s since last input",
        afterray_platform_macos::seconds_since_user_input()
    );
    match afterray_platform_macos::load_per_core() {
        Some(load) => println!("load            : {load:.2} per core"),
        None => println!("load            : unavailable"),
    }
}
