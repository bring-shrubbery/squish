//! Terminal colours and the human formats for sizes, ages and bars.

use std::fmt::Display;
use std::io::{IsTerminal, Write};
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum ColorChoice {
    Auto,
    Always,
    Never,
}

#[derive(Debug, Clone, Copy)]
pub struct Paint {
    pub enabled: bool,
}

impl Paint {
    /// Colours on a terminal, unless NO_COLOR is set or TERM is dumb.
    pub fn new(choice: ColorChoice) -> Paint {
        let enabled = match choice {
            ColorChoice::Always => true,
            ColorChoice::Never => false,
            ColorChoice::Auto => {
                std::io::stdout().is_terminal()
                    && std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty())
                    && std::env::var("TERM").map_or(true, |t| t != "dumb")
            }
        };
        Paint { enabled }
    }

    fn wrap(&self, code: &str, text: impl Display) -> String {
        if self.enabled { format!("\x1b[{code}m{text}\x1b[0m") } else { text.to_string() }
    }

    pub fn bold(&self, t: impl Display) -> String {
        self.wrap("1", t)
    }
    pub fn dim(&self, t: impl Display) -> String {
        self.wrap("2", t)
    }
    pub fn red(&self, t: impl Display) -> String {
        self.wrap("31", t)
    }
    pub fn green(&self, t: impl Display) -> String {
        self.wrap("32", t)
    }
    pub fn yellow(&self, t: impl Display) -> String {
        self.wrap("33", t)
    }
    pub fn blue(&self, t: impl Display) -> String {
        self.wrap("34", t)
    }
    pub fn magenta(&self, t: impl Display) -> String {
        self.wrap("35", t)
    }
    pub fn cyan(&self, t: impl Display) -> String {
        self.wrap("36", t)
    }
    pub fn purple_bold(&self, t: impl Display) -> String {
        self.wrap("1;35", t)
    }
}

/// Decimal units, as Finder and the app show them: 1 GB is 10^9 bytes.
pub fn bytes(n: u64) -> String {
    const UNITS: [&str; 5] = ["KB", "MB", "GB", "TB", "PB"];
    if n < 1000 {
        return format!("{n} B");
    }
    let mut value = n as f64;
    let mut unit = "B";
    for next in UNITS {
        if value < 1000.0 {
            break;
        }
        value /= 1000.0;
        unit = next;
    }
    let digits = if value >= 100.0 { format!("{value:.0}") } else { format!("{value:.1}") };
    format!("{} {unit}", digits.strip_suffix(".0").unwrap_or(&digits))
}

/// Parses sizes such as `500MB`, `1.5 GB`, `2G` or `1000000` (bytes).
pub fn parse_bytes(text: &str) -> Result<u64, String> {
    let cleaned = text.trim().to_ascii_lowercase().replace(' ', "");
    let split = cleaned.find(|c: char| !(c.is_ascii_digit() || c == '.')).unwrap_or(cleaned.len());
    let (number, unit) = cleaned.split_at(split);
    let value: f64 = number.parse().map_err(|_| format!("not a size: {text}"))?;
    let scale = match unit.trim_end_matches('b') {
        "" => 1.0,
        "k" => 1e3,
        "m" => 1e6,
        "g" => 1e9,
        "t" => 1e12,
        _ => return Err(format!("unknown size unit in {text}; use KB, MB, GB or TB")),
    };
    Ok((value * scale).round() as u64)
}

pub fn ago(idle: Duration) -> String {
    let s = idle.as_secs();
    match s {
        0..60 => "just now".into(),
        60..3_600 => plural(s / 60, "minute"),
        3_600..86_400 => plural(s / 3_600, "hour"),
        86_400..2_592_000 => plural(s / 86_400, "day"),
        2_592_000..31_536_000 => plural(s / 2_592_000, "month"),
        _ => plural(s / 31_536_000, "year"),
    }
}

fn plural(n: u64, unit: &str) -> String {
    format!("{n} {unit}{} ago", if n == 1 { "" } else { "s" })
}

/// A bar of `width` cells, filled in proportion to `value / max`.
pub fn bar(value: u64, max: u64, width: usize) -> (String, String) {
    let filled = if max == 0 { 0 } else { ((value as f64 / max as f64) * width as f64).ceil() as usize };
    let filled = filled.min(width);
    ("█".repeat(filled), "░".repeat(width - filled))
}

/// Cuts `text` to `width` characters, ending in `…` when cut.
pub fn truncate(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_string();
    }
    let kept: String = text.chars().take(width.saturating_sub(1)).collect();
    format!("{kept}…")
}

pub fn pad(text: &str, width: usize) -> String {
    let len = text.chars().count();
    format!("{text}{}", " ".repeat(width.saturating_sub(len)))
}

pub fn terminal_width() -> usize {
    ratatui::crossterm::terminal::size().map_or(100, |(w, _)| w as usize).clamp(60, 200)
}

/// A spinner line on stderr while scanning, cleared when done. Silent off a terminal.
pub struct Progress {
    enabled: bool,
    state: Mutex<(Instant, usize)>,
}

const FRAMES: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

impl Progress {
    pub fn new(enabled: bool) -> Progress {
        Progress {
            enabled: enabled && std::io::stderr().is_terminal(),
            state: Mutex::new((Instant::now() - Duration::from_secs(1), 0)),
        }
    }

    pub fn update(&self, message: impl FnOnce() -> String) {
        if !self.enabled {
            return;
        }
        let Ok(mut state) = self.state.try_lock() else { return };
        if state.0.elapsed() < Duration::from_millis(80) {
            return;
        }
        *state = (Instant::now(), state.1 + 1);
        let frame = FRAMES[state.1 % FRAMES.len()];
        let mut err = std::io::stderr().lock();
        let _ = write!(err, "\r\x1b[2K\x1b[35m{frame}\x1b[0m {}", message());
        let _ = err.flush();
    }

    pub fn clear(&self) {
        if self.enabled {
            let mut err = std::io::stderr().lock();
            let _ = write!(err, "\r\x1b[2K");
            let _ = err.flush();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_sizes() {
        assert_eq!(bytes(999), "999 B");
        assert_eq!(bytes(1_500), "1.5 KB");
        assert_eq!(bytes(640_000_000), "640 MB");
        assert_eq!(bytes(2_140_000_000), "2.1 GB");
        assert_eq!(bytes(1_000_000_000), "1 GB");
    }

    #[test]
    fn parses_sizes() {
        assert_eq!(parse_bytes("1GB"), Ok(1_000_000_000));
        assert_eq!(parse_bytes("500 mb"), Ok(500_000_000));
        assert_eq!(parse_bytes("1.5G"), Ok(1_500_000_000));
        assert_eq!(parse_bytes("42"), Ok(42));
        assert!(parse_bytes("lots").is_err());
        assert!(parse_bytes("3 parsecs").is_err());
    }

    #[test]
    fn formats_ages_and_bars() {
        assert_eq!(ago(Duration::from_secs(5)), "just now");
        assert_eq!(ago(Duration::from_secs(3_600)), "1 hour ago");
        assert_eq!(ago(Duration::from_secs(21 * 86_400)), "21 days ago");
        assert_eq!(bar(5, 10, 4), ("██".into(), "░░".into()));
        assert_eq!(bar(1, 1000, 4).0, "█");
        assert_eq!(truncate("feature/long-name", 8), "feature…");
    }
}
