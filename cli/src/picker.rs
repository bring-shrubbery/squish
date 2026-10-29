//! The interactive list `squish clean` opens on a terminal: move with the arrows, toggle with
//! space, confirm with enter.

use std::collections::BTreeSet;
use std::io;
use std::time::SystemTime;

use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{List, ListItem, ListState, Paragraph};
use ratatui::{DefaultTerminal, Frame};

use crate::paths::display;
use crate::report::{Entry, SortKey, sort};
use crate::style;
use crate::worktree::Removal;

struct Picker {
    title: String,
    entries: Vec<Entry>,
    selected: BTreeSet<String>,
    state: ListState,
    sort: SortKey,
    now: SystemTime,
    largest: u64,
}

/// Returns the chosen entries, or None when the user backed out. Flagged worktrees that can
/// go without losing work start selected.
pub fn pick(entries: Vec<Entry>, root_label: &str, now: SystemTime) -> io::Result<Option<Vec<Entry>>> {
    let selected = entries
        .iter()
        .filter(|e| matches!(e.removal, Removal::Clean | Removal::Prune) && (e.is_flagged() || e.worktree.is_prunable))
        .map(key)
        .collect();
    let largest = entries.iter().filter_map(|e| e.worktree.size_bytes).max().unwrap_or(0);
    let mut picker = Picker {
        title: format!("pick worktrees to remove · {root_label}"),
        entries,
        selected,
        state: ListState::default().with_selected(Some(0)),
        sort: SortKey::Size,
        now,
        largest,
    };
    sort(&mut picker.entries, picker.sort);
    let mut terminal = ratatui::init();
    let result = picker.run(&mut terminal);
    ratatui::restore();
    result
}

fn key(entry: &Entry) -> String {
    entry.worktree.path.display().to_string()
}

fn selectable(entry: &Entry) -> bool {
    !matches!(entry.removal, Removal::Blocked(_))
}

impl Picker {
    fn run(&mut self, terminal: &mut DefaultTerminal) -> io::Result<Option<Vec<Entry>>> {
        loop {
            terminal.draw(|frame| self.draw(frame))?;
            let Event::Key(press) = event::read()? else { continue };
            if press.kind != KeyEventKind::Press {
                continue;
            }
            let count = self.entries.len();
            let cursor = self.state.selected().unwrap_or(0);
            let page = terminal.size().map_or(10, |s| s.height.saturating_sub(8) as usize).max(1);
            match press.code {
                KeyCode::Char('q') | KeyCode::Esc => return Ok(None),
                KeyCode::Char('c') if press.modifiers.contains(KeyModifiers::CONTROL) => return Ok(None),
                KeyCode::Up | KeyCode::Char('k') => self.state.select(Some(cursor.saturating_sub(1))),
                KeyCode::Down | KeyCode::Char('j') => {
                    self.state.select(Some((cursor + 1).min(count.saturating_sub(1))))
                }
                KeyCode::PageUp => self.state.select(Some(cursor.saturating_sub(page))),
                KeyCode::PageDown => self.state.select(Some((cursor + page).min(count.saturating_sub(1)))),
                KeyCode::Home | KeyCode::Char('g') => self.state.select(Some(0)),
                KeyCode::End | KeyCode::Char('G') => self.state.select(Some(count.saturating_sub(1))),
                KeyCode::Char(' ') => {
                    if let Some(entry) = self.entries.get(cursor).filter(|e| selectable(e)) {
                        let key = key(entry);
                        if !self.selected.remove(&key) {
                            self.selected.insert(key);
                        }
                    }
                    self.state.select(Some((cursor + 1).min(count.saturating_sub(1))));
                }
                KeyCode::Char('a') => {
                    let all: BTreeSet<String> = self.entries.iter().filter(|e| selectable(e)).map(key).collect();
                    self.selected = if self.selected == all { BTreeSet::new() } else { all };
                }
                KeyCode::Char('f') => {
                    self.selected = self.entries.iter().filter(|e| selectable(e) && e.is_flagged()).map(key).collect();
                }
                KeyCode::Char('n') => self.selected.clear(),
                KeyCode::Char('s') => {
                    self.sort = match self.sort {
                        SortKey::Size => SortKey::Age,
                        SortKey::Age => SortKey::Repo,
                        SortKey::Repo | SortKey::Name => SortKey::Size,
                    };
                    sort(&mut self.entries, self.sort);
                }
                KeyCode::Enter => {
                    let chosen = self.entries.iter().filter(|e| self.selected.contains(&key(e))).cloned().collect();
                    return Ok(Some(chosen));
                }
                _ => {}
            }
        }
    }

    fn selected_bytes(&self) -> u64 {
        self.entries.iter().filter(|e| self.selected.contains(&key(e))).filter_map(|e| e.worktree.size_bytes).sum()
    }

    fn draw(&mut self, frame: &mut Frame) {
        let [header, list, detail, footer] =
            Layout::vertical([Constraint::Length(2), Constraint::Min(3), Constraint::Length(3), Constraint::Length(2)])
                .areas(frame.area());
        let accent = Style::new().fg(Color::Magenta).add_modifier(Modifier::BOLD);
        let dim = Style::new().add_modifier(Modifier::DIM);

        frame.render_widget(
            Paragraph::new(vec![
                Line::from(vec![
                    Span::styled(" squish  ", accent),
                    Span::styled(self.title.clone(), Style::new().add_modifier(Modifier::BOLD)),
                ]),
                Line::styled(format!(" {}", "─".repeat(header.width.saturating_sub(2) as usize)), dim),
            ]),
            header,
        );

        let width = list.width as usize;
        let repo_width = self.entries.iter().map(|e| e.worktree.repo_name().chars().count()).max().unwrap_or(4).min(18);
        let name_width = (width.saturating_sub(repo_width + 46)).clamp(12, 40);
        let items: Vec<ListItem> = self
            .entries
            .iter()
            .map(|e| {
                let w = &e.worktree;
                let checked = self.selected.contains(&key(e));
                let (mark, mark_style) = match (selectable(e), checked) {
                    (false, _) => ("[-]", dim),
                    (true, true) => ("[x]", Style::new().fg(Color::Green).add_modifier(Modifier::BOLD)),
                    (true, false) => ("[ ]", Style::new()),
                };
                let (full, empty) = style::bar(w.size_bytes.unwrap_or(0), self.largest, 8);
                let size = w.size_bytes.map(style::bytes).unwrap_or_else(|| "—".into());
                let age = w.idle(self.now).map(style::ago).unwrap_or_else(|| "—".into());
                let row_style = if selectable(e) { Style::new() } else { dim };
                let mut spans = vec![
                    Span::styled(format!("{mark} "), mark_style),
                    Span::styled(style::pad(&style::truncate(&w.repo_name(), repo_width), repo_width + 2), dim),
                    Span::styled(
                        style::pad(&style::truncate(&w.display_name(), name_width), name_width + 2),
                        row_style,
                    ),
                    Span::styled(format!("{size:>8} "), row_style),
                    Span::styled(full, Style::new().fg(Color::Magenta)),
                    Span::styled(empty, dim),
                    Span::styled(format!("  {}", style::pad(&age, 14)), dim),
                ];
                spans.extend(notes(e));
                ListItem::new(Line::from(spans))
            })
            .collect();
        frame.render_stateful_widget(
            List::new(items)
                .highlight_symbol(Span::styled(" ❯ ", accent))
                .highlight_style(Style::new().add_modifier(Modifier::REVERSED).remove_modifier(Modifier::DIM))
                .highlight_spacing(ratatui::widgets::HighlightSpacing::Always),
            list,
            &mut self.state,
        );

        let focused = self.state.selected().and_then(|i| self.entries.get(i));
        let detail_lines = match focused {
            None => vec![Line::styled(" No linked worktrees here.", dim)],
            Some(e) => {
                let w = &e.worktree;
                let head = &w.head[..w.head.len().min(10)];
                let what = match &e.removal {
                    Removal::Clean => "Clean: removed with git worktree remove; the branch stays.".to_string(),
                    Removal::LosesWork { uncommitted, unpushed, .. } => format!(
                        "Has work found nowhere else ({uncommitted} uncommitted, {unpushed} unpushed); asks again before removing."
                    ),
                    Removal::Prune => "Its directory is gone; git worktree prune clears the record.".to_string(),
                    Removal::Blocked(reason) => format!("Can't remove: {reason}."),
                };
                vec![
                    Line::from(vec![
                        Span::styled(" ", dim),
                        Span::styled(display(&w.path), Style::new().add_modifier(Modifier::BOLD)),
                    ]),
                    Line::styled(format!(" HEAD {head} · repo {}", display(&w.repo)), dim),
                    Line::styled(format!(" {what}"), dim),
                ]
            }
        };
        frame.render_widget(Paragraph::new(detail_lines), detail);

        let sort_label = match self.sort {
            SortKey::Size => "size",
            SortKey::Age => "age",
            SortKey::Repo | SortKey::Name => "repo",
        };
        let picked = self.selected.len();
        frame.render_widget(
            Paragraph::new(vec![
                Line::from(vec![
                    Span::styled(" ↑↓ ", accent),
                    Span::raw("move  "),
                    Span::styled("space ", accent),
                    Span::raw("select  "),
                    Span::styled("f ", accent),
                    Span::raw("flagged  "),
                    Span::styled("a ", accent),
                    Span::raw("all  "),
                    Span::styled("n ", accent),
                    Span::raw("none  "),
                    Span::styled("s ", accent),
                    Span::raw(format!("sort: {sort_label}  ")),
                    Span::styled("enter ", accent),
                    Span::raw("review  "),
                    Span::styled("q ", accent),
                    Span::raw("quit"),
                ]),
                Line::from(vec![
                    Span::styled(format!(" {picked} selected"), Style::new().add_modifier(Modifier::BOLD)),
                    Span::styled(format!(" · {}", style::bytes(self.selected_bytes())), Style::new().fg(Color::Green)),
                    Span::styled("  · nothing is removed until you confirm", dim),
                ]),
            ]),
            footer,
        );
    }
}

fn notes(entry: &Entry) -> Vec<Span<'static>> {
    let w = &entry.worktree;
    let mut notes: Vec<(String, Color)> = Vec::new();
    if w.is_prunable {
        notes.push(("missing".into(), Color::Yellow));
    }
    if w.detail_error.is_some() {
        notes.push(("unreadable".into(), Color::Red));
    }
    if entry.active {
        notes.push(("in use".into(), Color::Cyan));
    }
    if w.is_locked {
        notes.push(("locked".into(), Color::Gray));
    }
    if entry.is_stale() {
        notes.push(("stale".into(), Color::Yellow));
    }
    if entry.is_large() {
        notes.push(("large".into(), Color::Yellow));
    }
    if w.uncommitted > 0 {
        notes.push((format!("{} uncommitted", w.uncommitted), Color::Magenta));
    }
    if w.unpushed > 0 {
        notes.push((format!("{} unpushed", w.unpushed), Color::Magenta));
    }
    if let Some(agent) = w.agent() {
        notes.push((agent.name().into(), Color::Blue));
    }
    let mut spans = Vec::new();
    for (i, (text, color)) in notes.into_iter().enumerate() {
        if i > 0 {
            spans.push(Span::styled(" · ", Style::new().add_modifier(Modifier::DIM)));
        }
        spans.push(Span::styled(text, Style::new().fg(color)));
    }
    spans
}
