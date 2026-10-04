use std::{
    env, io, mem,
    process::Stdio,
    time::{Duration, Instant},
};

use crossterm::{
    event::{
        self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyModifiers, MouseEventKind,
    },
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    prelude::*,
    widgets::{Block, Borders, Paragraph, Wrap},
};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    sync::mpsc,
    task::JoinHandle,
};

#[cfg(unix)]
struct FollowerProcessGroup(u32);

#[cfg(unix)]
impl Drop for FollowerProcessGroup {
    fn drop(&mut self) {
        // The follower starts its own group, so this cannot signal the TUI
        // or its shell. Kill descendants as well as the traj wrapper.
        unsafe {
            libc::kill(-(self.0 as libc::pid_t), libc::SIGKILL);
        }
    }
}

struct Message {
    sender: String,
    content: String,
    is_agent: bool,
}

#[derive(Clone, PartialEq)]
enum Mode {
    Chat,
    Thinkers,
    Traj,
    Command,
}

struct App {
    messages: Vec<Message>,
    input: String,
    cursor: usize,
    identity_name: String,
    from: Option<String>,
    scroll_offset: usize,
    kill_ring: String,
    chat_history: Vec<String>,
    thinkers_history: Vec<String>,
    traj_history: Vec<String>,
    command_history: Vec<String>,
    history_idx: Option<usize>,
    stashed_input: String,
    mode: Mode,
    cmd_output: Vec<String>,
    cmd_scroll: usize,
    cmd_base: String,
    mouse_captured: bool,
    quit_armed: Option<Instant>,
    refresh_paused: bool,
}

impl App {
    fn mode_title(&self) -> String {
        match self.mode {
            Mode::Chat => format!(" {} ", self.identity_name),
            Mode::Thinkers => " thinkers ".to_string(),
            Mode::Traj => " traj ".to_string(),
            Mode::Command => format!(" {} ", self.cmd_base),
        }
    }

    fn scroll_up(&mut self, n: usize) {
        match self.mode {
            Mode::Chat => self.scroll_offset += n,
            _ => self.cmd_scroll += n,
        }
    }

    fn scroll_down(&mut self, n: usize) {
        match self.mode {
            Mode::Chat => self.scroll_offset = self.scroll_offset.saturating_sub(n),
            _ => self.cmd_scroll = self.cmd_scroll.saturating_sub(n),
        }
    }

    /// History bucket for the current mode.
    fn history(&self) -> &Vec<String> {
        match self.mode {
            Mode::Chat => &self.chat_history,
            Mode::Thinkers => &self.thinkers_history,
            Mode::Traj => &self.traj_history,
            Mode::Command => &self.command_history,
        }
    }

    fn history_mut(&mut self) -> &mut Vec<String> {
        match self.mode {
            Mode::Chat => &mut self.chat_history,
            Mode::Thinkers => &mut self.thinkers_history,
            Mode::Traj => &mut self.traj_history,
            Mode::Command => &mut self.command_history,
        }
    }

    fn history_prev(&mut self) {
        if self.history().is_empty() {
            return;
        }
        let idx = match self.history_idx {
            None => {
                self.stashed_input = self.input.clone();
                self.history().len() - 1
            }
            Some(i) if i > 0 => i - 1,
            Some(i) => i,
        };
        self.history_idx = Some(idx);
        self.input = self.history()[idx].clone();
        self.cursor = self.input.chars().count();
    }

    fn history_next(&mut self) {
        let Some(idx) = self.history_idx else { return };
        if idx + 1 < self.history().len() {
            let next = idx + 1;
            self.history_idx = Some(next);
            self.input = self.history()[next].clone();
        } else {
            self.history_idx = None;
            self.input = mem::take(&mut self.stashed_input);
        }
        self.cursor = self.input.chars().count();
    }
}

fn shell_escape(s: &str) -> String {
    if s.is_empty() {
        return "''".to_string();
    }
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn byte_pos(s: &str, char_idx: usize) -> usize {
    s.char_indices().nth(char_idx).map_or(s.len(), |(i, _)| i)
}

/// Calculate display (col, row) for a cursor position in wrapped text.
fn cursor_xy(input: &str, cursor: usize, width: usize) -> (u16, u16) {
    if width == 0 {
        return (0, 0);
    }
    let mut col = 0usize;
    let mut row = 0usize;
    for (i, ch) in input.chars().enumerate() {
        if i == cursor {
            break;
        }
        if ch == '\n' {
            row += 1;
            col = 0;
        } else {
            col += 1;
            if col >= width {
                col = 0;
                row += 1;
            }
        }
    }
    (col as u16, row as u16)
}

/// Character-wrap input into display lines (matches cursor_xy behavior exactly).
fn wrap_input(input: &str, width: usize) -> Vec<String> {
    if width == 0 {
        return vec![input.to_string()];
    }
    let mut lines = Vec::new();
    for line in input.split('\n') {
        let chars: Vec<char> = line.chars().collect();
        if chars.is_empty() {
            lines.push(String::new());
        } else {
            for chunk in chars.chunks(width) {
                lines.push(chunk.iter().collect());
            }
        }
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

/// Parse a line containing ANSI SGR escape sequences into styled ratatui Spans.
fn parse_ansi_line(line: &str) -> Line<'static> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut style = Style::default();
    let mut buf = String::new();
    let chars: Vec<char> = line.chars().collect();
    let len = chars.len();
    let mut i = 0;

    while i < len {
        if chars[i] == '\x1b' && i + 1 < len && chars[i + 1] == '[' {
            // Flush text accumulated so far
            if !buf.is_empty() {
                spans.push(Span::styled(mem::take(&mut buf), style));
            }
            // Parse CSI sequence: ESC [ <params> m
            i += 2; // skip ESC [
            let mut params = String::new();
            while i < len && chars[i] != 'm' {
                // Stop if we hit a letter that isn't 'm' (not an SGR sequence)
                if chars[i].is_ascii_alphabetic() {
                    break;
                }
                params.push(chars[i]);
                i += 1;
            }
            if i < len && chars[i] == 'm' {
                i += 1; // skip 'm'
                        // Apply SGR codes
                let codes: Vec<&str> = params.split(';').collect();
                let mut ci = 0;
                while ci < codes.len() {
                    let code: u8 = codes[ci].parse().unwrap_or(0);
                    match code {
                        0 => style = Style::default(),
                        1 => style = style.add_modifier(Modifier::BOLD),
                        2 => style = style.add_modifier(Modifier::DIM),
                        3 => style = style.add_modifier(Modifier::ITALIC),
                        4 => style = style.add_modifier(Modifier::UNDERLINED),
                        22 => style = style.remove_modifier(Modifier::BOLD | Modifier::DIM),
                        23 => style = style.remove_modifier(Modifier::ITALIC),
                        24 => style = style.remove_modifier(Modifier::UNDERLINED),
                        30 => style = style.fg(Color::Black),
                        31 => style = style.fg(Color::Red),
                        32 => style = style.fg(Color::Green),
                        33 => style = style.fg(Color::Yellow),
                        34 => style = style.fg(Color::Blue),
                        35 => style = style.fg(Color::Magenta),
                        36 => style = style.fg(Color::Cyan),
                        37 => style = style.fg(Color::White),
                        38 => {
                            // 256-color or RGB foreground
                            if ci + 2 < codes.len() && codes[ci + 1] == "5" {
                                if let Ok(n) = codes[ci + 2].parse::<u8>() {
                                    style = style.fg(Color::Indexed(n));
                                }
                                ci += 2;
                            }
                        }
                        39 => style = style.fg(Color::Reset),
                        40 => style = style.bg(Color::Black),
                        41 => style = style.bg(Color::Red),
                        42 => style = style.bg(Color::Green),
                        43 => style = style.bg(Color::Yellow),
                        44 => style = style.bg(Color::Blue),
                        45 => style = style.bg(Color::Magenta),
                        46 => style = style.bg(Color::Cyan),
                        47 => style = style.bg(Color::White),
                        48 => {
                            if ci + 2 < codes.len() && codes[ci + 1] == "5" {
                                if let Ok(n) = codes[ci + 2].parse::<u8>() {
                                    style = style.bg(Color::Indexed(n));
                                }
                                ci += 2;
                            }
                        }
                        49 => style = style.bg(Color::Reset),
                        90 => style = style.fg(Color::DarkGray),
                        91 => style = style.fg(Color::LightRed),
                        92 => style = style.fg(Color::LightGreen),
                        93 => style = style.fg(Color::LightYellow),
                        94 => style = style.fg(Color::LightBlue),
                        95 => style = style.fg(Color::LightMagenta),
                        96 => style = style.fg(Color::LightCyan),
                        97 => style = style.fg(Color::White),
                        _ => {}
                    }
                    ci += 1;
                }
            } else {
                // Not a valid SGR sequence, emit the raw text
                buf.push('\x1b');
                buf.push('[');
                buf.push_str(&params);
                if i < len {
                    buf.push(chars[i]);
                    i += 1;
                }
            }
        } else {
            buf.push(chars[i]);
            i += 1;
        }
    }

    if !buf.is_empty() {
        spans.push(Span::styled(buf, style));
    }

    if spans.is_empty() {
        Line::raw("")
    } else {
        Line::from(spans)
    }
}

fn help_text() -> Vec<String> {
    vec![
        "Modes:".into(),
        "  /chat          Chat with the identity".into(),
        "  /thinkers      Monitor & control thinkers".into(),
        "  /identities    Identity management".into(),
        "  /skills        Skills management".into(),
        "  /traj          Trajectory inspection".into(),
        "  /help          Show this help".into(),
        "".into(),
        "In each mode, type a subcommand and press Enter.".into(),
        "Examples:".into(),
        "  (chat)      hello there        -> chat send hello there".into(),
        "  (thinkers)  start executive    -> thinkers start executive".into(),
        "  (traj)      tail -n 5          -> traj tail -n 5".into(),
        "".into(),
        "Keys:".into(),
        "  Ctrl+C         Exit (press twice)".into(),
        "  Ctrl+D         Delete char at cursor (exit if input empty)".into(),
        "  Shift+Enter    Newline in input".into(),
        "  Up/Down        Command history (from top/bottom line)".into(),
        "  Enter (empty)  Return to live view after a command (thinkers/traj)".into(),
        "  PageUp/Down    Scroll output".into(),
        "  Ctrl+G         Toggle mouse (scroll vs. text select)".into(),
        "  Option+click   Select text (iTerm2) without toggling".into(),
    ]
}

/// Run a command and return its combined stdout+stderr lines.
async fn run_cmd(program: &str, args: &[&str]) -> Vec<String> {
    let Ok(output) = tokio::process::Command::new(program)
        .args(args)
        .env("CLICOLOR_FORCE", "1")
        .env("FORCE_COLOR", "1")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
    else {
        return vec![format!("Failed to run: {} {}", program, args.join(" "))];
    };
    let mut lines: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|l| l.to_string())
        .collect();
    let stderr_lines: Vec<String> = String::from_utf8_lossy(&output.stderr)
        .lines()
        .map(|l| l.to_string())
        .collect();
    for l in stderr_lines {
        if !l.is_empty() {
            lines.push(l);
        }
    }
    lines
}

/// Spawn an auto-refresh task that runs a command every `interval` seconds.
fn spawn_auto_refresh(
    tx: mpsc::UnboundedSender<Vec<String>>,
    program: String,
    args: Vec<String>,
    interval: Duration,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
            let output = run_cmd(&program, &arg_refs).await;
            if tx.send(output).is_err() {
                break;
            }
            tokio::time::sleep(interval).await;
        }
    })
}

fn parse_mode(s: &str) -> Mode {
    match s {
        "thinkers" => Mode::Thinkers,
        "traj" => Mode::Traj,
        "chat" => Mode::Chat,
        _ => Mode::Chat,
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let identity_name = env::var("IDENTITY_NAME").unwrap_or_else(|_| "agent".into());

    let mut from: Option<String> = None;
    let mut initial_mode = Mode::Chat;
    let args: Vec<String> = env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" | "help" => {
                println!("headlong-tui — Interactive terminal UI for Headlong\n");
                println!("Usage: headlong-tui [MODE] [--from NAME]\n");
                println!("Modes:");
                println!("  chat        Chat with the identity (default)");
                println!("  thinkers    Monitor & control thinkers");
                println!("  traj        Trajectory viewer\n");
                println!("Options:");
                println!("  --from NAME   Set sender name for chat messages");
                println!("  --mode MODE   Set initial mode (same as positional)\n");
                println!("Slash commands (available in any mode):");
                println!("  /chat  /thinkers  /traj  /identities  /help\n");
                println!("Keys:");
                println!("  Ctrl+C         Exit (press twice)");
                println!("  Ctrl+D         Delete char at cursor (exit if input empty)");
                println!("  Shift+Enter    Newline in input");
                println!("  PageUp/Down    Scroll output");
                println!("  Ctrl+G         Toggle mouse (scroll vs. text select)");
                return Ok(());
            }
            "--from" => {
                i += 1;
                from = args.get(i).cloned();
            }
            "--mode" => {
                i += 1;
                if let Some(m) = args.get(i) {
                    initial_mode = parse_mode(m);
                }
            }
            arg if !arg.starts_with('-') && i == 0 => {
                initial_mode = parse_mode(arg);
            }
            _ => {}
        }
        i += 1;
    }

    enable_raw_mode()?;
    execute!(io::stdout(), EnterAlternateScreen, EnableMouseCapture)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))?;

    let result = run(&mut terminal, identity_name, from, initial_mode).await;

    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        DisableMouseCapture,
        LeaveAlternateScreen
    )?;

    result
}

async fn run(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    identity_name: String,
    from: Option<String>,
    initial_mode: Mode,
) -> Result<(), Box<dyn std::error::Error>> {
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<Vec<String>>();

    let id_name = identity_name.clone();
    let parse_and_send = |line: &str, tx: &mpsc::UnboundedSender<Message>, id: &str| {
        let Ok(json) = serde_json::from_str::<serde_json::Value>(line) else {
            return;
        };
        let step_type = json["type"].as_str().unwrap_or("");
        let content = json["content"].as_str().unwrap_or("").to_string();
        if content.is_empty() {
            return;
        }
        let (sender, is_agent) = match step_type {
            "message" => {
                let from = json["from"].as_str().unwrap_or("unknown").to_string();
                let is_self = from == id;
                (from, is_self)
            }
            // Legacy types for backward compat with old trajectories
            "human-msg" => (json["from"].as_str().unwrap_or("you").to_string(), false),
            "agent-msg" => (id.to_string(), true),
            _ => return,
        };
        let _ = tx.send(Message {
            sender,
            content,
            is_agent,
        });
    };

    // Phase 1: load recent history via `traj cat --filter | tail -n 20`
    // Use ROOT_TRAJ_ID so we always read from the root trajectory
    let id_hist = id_name.clone();
    let tx_hist = tx.clone();
    let history_loader = tokio::spawn(async move {
        let traj_id = env::var("ROOT_TRAJ_ID")
            .or_else(|_| env::var("TRAJ_ID"))
            .unwrap_or_default();
        let cmd = format!(
            "traj cat {} --filter type=message,human-msg,agent-msg --raw 2>/dev/null | tail -n 20",
            shell_escape(&traj_id)
        );
        let Ok(output) = tokio::process::Command::new("bash")
            .args(["-c", &cmd])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .await
        else {
            return;
        };
        let text = String::from_utf8_lossy(&output.stdout);
        for line in text.lines() {
            parse_and_send(line, &tx_hist, &id_hist);
        }
    });

    // Wait for history to load before starting the follow watcher
    let _ = history_loader.await;

    // Phase 2: follow new messages via `traj tail -f -n 0`
    // Use ROOT_TRAJ_ID so we follow the root trajectory
    let tx_err = tx.clone();
    let watcher = tokio::spawn(async move {
        let traj_id = env::var("ROOT_TRAJ_ID")
            .or_else(|_| env::var("TRAJ_ID"))
            .unwrap_or_default();
        let mut args = vec![
            "tail",
            "-f",
            "--filter",
            "type=message,human-msg,agent-msg",
            "-n",
            "0",
            "--raw",
        ];
        let traj_id_owned;
        if !traj_id.is_empty() {
            traj_id_owned = traj_id;
            args.push(&traj_id_owned);
        }
        let mut command = tokio::process::Command::new("traj");
        command
            .args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.as_std_mut().process_group(0);
        }
        let Ok(mut child) = command.spawn() else {
            return;
        };
        #[cfg(unix)]
        let _process_group = child.id().map(FollowerProcessGroup);
        let Some(stdout) = child.stdout.take() else {
            return;
        };
        let mut lines = BufReader::new(stdout).lines();

        while let Ok(Some(line)) = lines.next_line().await {
            parse_and_send(&line, &tx, &id_name);
        }
    });

    // Auto-refresh handle (only active in thinkers mode)
    let mut auto_refresh: Option<JoinHandle<()>> = None;

    // Kick off auto-refresh for modes that need it
    match initial_mode {
        Mode::Thinkers => {
            auto_refresh = Some(spawn_auto_refresh(
                cmd_tx.clone(),
                "thinkers".into(),
                vec!["status".into()],
                Duration::from_secs(2),
            ));
        }
        Mode::Traj => {
            auto_refresh = Some(spawn_auto_refresh(
                cmd_tx.clone(),
                "traj".into(),
                vec!["tail".into(), "-r".into(), "-n".into(), "50".into()],
                Duration::from_secs(2),
            ));
        }
        _ => {}
    }

    let mut app = App {
        messages: Vec::new(),
        input: String::new(),
        cursor: 0,
        identity_name,
        from,
        scroll_offset: 0,
        kill_ring: String::new(),
        chat_history: Vec::new(),
        thinkers_history: Vec::new(),
        traj_history: Vec::new(),
        command_history: Vec::new(),
        history_idx: None,
        stashed_input: String::new(),
        mode: initial_mode,
        cmd_output: Vec::new(),
        cmd_scroll: 0,
        cmd_base: String::new(),
        mouse_captured: true,
        quit_armed: None,
        refresh_paused: false,
    };

    let mut needs_clear = false;

    loop {
        while let Ok(msg) = rx.try_recv() {
            app.messages.push(msg);
            if app.mode == Mode::Chat {
                app.scroll_offset = 0;
                needs_clear = true;
            }
        }

        while let Ok(lines) = cmd_rx.try_recv() {
            app.cmd_output = lines;
        }

        if app
            .quit_armed
            .is_some_and(|t| t.elapsed() > Duration::from_secs(2))
        {
            app.quit_armed = None;
        }

        // Force full redraw when chat messages change to avoid
        // differential rendering artifacts (stale content bleeding
        // across widget boundaries after scroll changes).
        if needs_clear {
            terminal.clear()?;
            needs_clear = false;
        }

        terminal.draw(|f| draw(f, &app))?;

        if event::poll(Duration::from_millis(50))? {
            let ev = event::read()?;
            if let Event::Mouse(mouse) = &ev {
                match mouse.kind {
                    MouseEventKind::ScrollUp => app.scroll_up(3),
                    MouseEventKind::ScrollDown => app.scroll_down(3),
                    _ => {}
                }
            }
            if let Event::Key(key) = ev {
                if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
                    if app.quit_armed.is_some() {
                        break;
                    }
                    app.quit_armed = Some(Instant::now());
                    continue;
                }
                app.quit_armed = None;
                match key.code {
                    KeyCode::Esc => break,
                    KeyCode::Char('g') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        app.mouse_captured = !app.mouse_captured;
                        if app.mouse_captured {
                            execute!(io::stdout(), EnableMouseCapture)?;
                        } else {
                            execute!(io::stdout(), DisableMouseCapture)?;
                        }
                    }
                    KeyCode::Enter if key.modifiers.contains(KeyModifiers::SHIFT) => {
                        let pos = byte_pos(&app.input, app.cursor);
                        app.input.insert(pos, '\n');
                        app.cursor += 1;
                    }
                    KeyCode::Enter => {
                        if app.input.is_empty() {
                            // Empty Enter resumes the live view after a one-off command
                            if app.refresh_paused {
                                app.refresh_paused = false;
                                app.cmd_scroll = 0;
                                app.cmd_output = vec!["Loading...".into()];
                                if let Some(h) = auto_refresh.take() {
                                    h.abort();
                                }
                                auto_refresh = Some(match app.mode {
                                    Mode::Thinkers => spawn_auto_refresh(
                                        cmd_tx.clone(),
                                        "thinkers".into(),
                                        vec!["status".into()],
                                        Duration::from_secs(2),
                                    ),
                                    _ => spawn_auto_refresh(
                                        cmd_tx.clone(),
                                        "traj".into(),
                                        vec!["tail".into(), "-r".into(), "-n".into(), "50".into()],
                                        Duration::from_secs(2),
                                    ),
                                });
                            }
                        } else {
                            let msg = mem::take(&mut app.input);
                            app.cursor = 0;
                            app.history_idx = None;
                            let hist = app.history_mut();
                            if hist.last() != Some(&msg) {
                                hist.push(msg.clone());
                            }
                            let trimmed = msg.trim();

                            // Slash command handling (available in all modes)
                            if trimmed.starts_with('/') {
                                app.refresh_paused = false;
                            }
                            if trimmed == "/thinkers" {
                                app.mode = Mode::Thinkers;
                                app.cmd_output = vec!["Loading...".into()];
                                app.cmd_scroll = 0;
                                app.cmd_base.clear();
                                // Start auto-refresh
                                if let Some(h) = auto_refresh.take() {
                                    h.abort();
                                }
                                auto_refresh = Some(spawn_auto_refresh(
                                    cmd_tx.clone(),
                                    "thinkers".into(),
                                    vec!["status".into()],
                                    Duration::from_secs(2),
                                ));
                            } else if trimmed == "/chat" {
                                app.mode = Mode::Chat;
                                app.scroll_offset = 0;
                                app.cmd_output.clear();
                                app.cmd_scroll = 0;
                                app.cmd_base.clear();
                                // Stop auto-refresh
                                if let Some(h) = auto_refresh.take() {
                                    h.abort();
                                }
                            } else if trimmed == "/help" {
                                app.mode = Mode::Command;
                                app.cmd_output = help_text();
                                app.cmd_scroll = 0;
                                app.cmd_base = "help".into();
                                if let Some(h) = auto_refresh.take() {
                                    h.abort();
                                }
                            } else if trimmed == "/identities" {
                                app.mode = Mode::Command;
                                app.cmd_output = vec!["Loading...".into()];
                                app.cmd_scroll = 0;
                                app.cmd_base = "identity".into();
                                if let Some(h) = auto_refresh.take() {
                                    h.abort();
                                }
                                let tx = cmd_tx.clone();
                                tokio::spawn(async move {
                                    let output = run_cmd("identity", &["list"]).await;
                                    let _ = tx.send(output);
                                });
                            } else if trimmed == "/skills" {
                                app.mode = Mode::Command;
                                app.cmd_output = vec!["Loading...".into()];
                                app.cmd_scroll = 0;
                                app.cmd_base = "skills".into();
                                if let Some(h) = auto_refresh.take() {
                                    h.abort();
                                }
                                let tx = cmd_tx.clone();
                                tokio::spawn(async move {
                                    let output = run_cmd("skills", &["list"]).await;
                                    let _ = tx.send(output);
                                });
                            } else if trimmed == "/traj" {
                                app.mode = Mode::Traj;
                                app.cmd_output = vec!["Loading...".into()];
                                app.cmd_scroll = 0;
                                app.cmd_base.clear();
                                if let Some(h) = auto_refresh.take() {
                                    h.abort();
                                }
                                auto_refresh = Some(spawn_auto_refresh(
                                    cmd_tx.clone(),
                                    "traj".into(),
                                    vec!["tail".into(), "-r".into(), "-n".into(), "50".into()],
                                    Duration::from_secs(2),
                                ));
                            } else {
                                // Mode-specific dispatch
                                match app.mode {
                                    Mode::Chat => {
                                        app.scroll_offset = 0;
                                        let from = app.from.clone();
                                        let msg_owned = msg;
                                        let err_tx = tx_err.clone();
                                        tokio::spawn(async move {
                                            let mut cmd = tokio::process::Command::new("chat");
                                            cmd.arg("send");
                                            if let Some(ref f) = from {
                                                cmd.args(["--from", f]);
                                            }
                                            cmd.arg(&msg_owned)
                                                .stdout(Stdio::null())
                                                .stderr(Stdio::piped());
                                            if let Ok(output) = cmd.output().await {
                                                if !output.status.success() {
                                                    let stderr =
                                                        String::from_utf8_lossy(&output.stderr)
                                                            .trim()
                                                            .to_string();
                                                    if !stderr.is_empty() {
                                                        let _ = err_tx.send(Message {
                                                            sender: "system".into(),
                                                            content: stderr,
                                                            is_agent: false,
                                                        });
                                                    }
                                                }
                                            }
                                        });
                                    }
                                    Mode::Thinkers => {
                                        if let Some(h) = auto_refresh.take() {
                                            h.abort();
                                        }
                                        app.refresh_paused = true;
                                        let tx = cmd_tx.clone();
                                        let args_str = msg;
                                        tokio::spawn(async move {
                                            let parts: Vec<&str> =
                                                args_str.split_whitespace().collect();
                                            let output = run_cmd("thinkers", &parts).await;
                                            let _ = tx.send(output);
                                        });
                                    }
                                    Mode::Traj => {
                                        if let Some(h) = auto_refresh.take() {
                                            h.abort();
                                        }
                                        app.refresh_paused = true;
                                        let tx = cmd_tx.clone();
                                        let args_str = msg;
                                        tokio::spawn(async move {
                                            let parts: Vec<&str> =
                                                args_str.split_whitespace().collect();
                                            let output = run_cmd("traj", &parts).await;
                                            let _ = tx.send(output);
                                        });
                                    }
                                    Mode::Command => {
                                        if app.cmd_base == "help" {
                                            // In help mode, just re-show help
                                            app.cmd_output = help_text();
                                            app.cmd_scroll = 0;
                                        } else {
                                            let tx = cmd_tx.clone();
                                            let base = app.cmd_base.clone();
                                            let args_str = msg;
                                            tokio::spawn(async move {
                                                let parts: Vec<&str> =
                                                    args_str.split_whitespace().collect();
                                                let output = run_cmd(&base, &parts).await;
                                                let _ = tx.send(output);
                                            });
                                        }
                                    }
                                }
                            }
                        }
                    }
                    KeyCode::Char('a') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        app.cursor = 0;
                    }
                    KeyCode::Char('e') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        app.cursor = app.input.chars().count();
                    }
                    KeyCode::Char('b') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        app.cursor = app.cursor.saturating_sub(1);
                    }
                    KeyCode::Char('f') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        let len = app.input.chars().count();
                        if app.cursor < len {
                            app.cursor += 1;
                        }
                    }
                    KeyCode::Char('d') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        // Readline delete-char; EOF (exit) on empty input
                        if app.input.is_empty() {
                            break;
                        }
                        let len = app.input.chars().count();
                        if app.cursor < len {
                            let pos = byte_pos(&app.input, app.cursor);
                            app.input.remove(pos);
                        }
                    }
                    KeyCode::Char('k') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        let pos = byte_pos(&app.input, app.cursor);
                        app.kill_ring = app.input[pos..].to_string();
                        app.input.truncate(pos);
                    }
                    KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        let pos = byte_pos(&app.input, app.cursor);
                        app.kill_ring = app.input[..pos].to_string();
                        app.input.drain(..pos);
                        app.cursor = 0;
                    }
                    KeyCode::Char('w') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        if app.cursor > 0 {
                            let s: Vec<char> = app.input.chars().collect();
                            let mut i = app.cursor;
                            while i > 0 && s[i - 1] == ' ' {
                                i -= 1;
                            }
                            while i > 0 && s[i - 1] != ' ' {
                                i -= 1;
                            }
                            let from = byte_pos(&app.input, i);
                            let to = byte_pos(&app.input, app.cursor);
                            app.kill_ring = app.input[from..to].to_string();
                            app.input.drain(from..to);
                            app.cursor = i;
                        }
                    }
                    KeyCode::Char('p') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        let inner_w =
                            terminal.size().map_or(78, |s| s.width.saturating_sub(2)) as usize;
                        let (cx, cy) = cursor_xy(&app.input, app.cursor, inner_w);
                        if cy > 0 {
                            // Move cursor up one display row
                            app.cursor = char_at_xy(&app.input, cx, cy - 1, inner_w);
                        } else {
                            // At top line — cycle history
                            app.history_prev();
                        }
                    }
                    KeyCode::Char('n') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        let inner_w =
                            terminal.size().map_or(78, |s| s.width.saturating_sub(2)) as usize;
                        let (cx, cy) = cursor_xy(&app.input, app.cursor, inner_w);
                        let total = wrap_input(&app.input, inner_w).len() as u16;
                        if cy + 1 < total {
                            // Move cursor down one display row
                            app.cursor = char_at_xy(&app.input, cx, cy + 1, inner_w);
                        } else {
                            // At bottom line — cycle history
                            app.history_next();
                        }
                    }
                    KeyCode::Char('y') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        if !app.kill_ring.is_empty() {
                            let pos = byte_pos(&app.input, app.cursor);
                            let yanked = app.kill_ring.clone();
                            let char_count = yanked.chars().count();
                            app.input.insert_str(pos, &yanked);
                            app.cursor += char_count;
                        }
                    }
                    KeyCode::Char(c) => {
                        let pos = byte_pos(&app.input, app.cursor);
                        app.input.insert(pos, c);
                        app.cursor += 1;
                    }
                    KeyCode::Backspace => {
                        if app.cursor > 0 {
                            app.cursor -= 1;
                            let pos = byte_pos(&app.input, app.cursor);
                            app.input.remove(pos);
                        }
                    }
                    KeyCode::Left => app.cursor = app.cursor.saturating_sub(1),
                    KeyCode::Right => {
                        let len = app.input.chars().count();
                        if app.cursor < len {
                            app.cursor += 1;
                        }
                    }
                    KeyCode::Up => {
                        // Move cursor up one display row; recall history from the top row
                        let inner_w =
                            terminal.size().map_or(78, |s| s.width.saturating_sub(2)) as usize;
                        if inner_w > 0 {
                            let (cx, cy) = cursor_xy(&app.input, app.cursor, inner_w);
                            if cy > 0 {
                                app.cursor = char_at_xy(&app.input, cx, cy - 1, inner_w);
                            } else {
                                app.history_prev();
                            }
                        }
                    }
                    KeyCode::Down => {
                        let inner_w =
                            terminal.size().map_or(78, |s| s.width.saturating_sub(2)) as usize;
                        if inner_w > 0 {
                            let (cx, cy) = cursor_xy(&app.input, app.cursor, inner_w);
                            let total = wrap_input(&app.input, inner_w).len() as u16;
                            if cy + 1 < total {
                                app.cursor = char_at_xy(&app.input, cx, cy + 1, inner_w);
                            } else {
                                app.history_next();
                            }
                        }
                    }
                    KeyCode::PageUp => app.scroll_up(5),
                    KeyCode::PageDown => app.scroll_down(5),
                    _ => {}
                }
            }
        }
    }

    if let Some(h) = auto_refresh.take() {
        h.abort();
    }
    watcher.abort();
    Ok(())
}

/// Find the char index at a given display (col, row), clamping to line boundaries.
fn char_at_xy(input: &str, target_col: u16, target_row: u16, width: usize) -> usize {
    if width == 0 {
        return 0;
    }
    let mut col = 0usize;
    let mut row = 0usize;
    let target_col = target_col as usize;
    let target_row = target_row as usize;
    let mut last_idx = 0;

    for (i, ch) in input.chars().enumerate() {
        if row == target_row && col == target_col {
            return i;
        }
        if row > target_row {
            return last_idx;
        }
        last_idx = i;
        if ch == '\n' {
            if row == target_row {
                // Target col is past end of this line
                return i;
            }
            row += 1;
            col = 0;
        } else {
            col += 1;
            if col >= width {
                if row == target_row && col == target_col {
                    return i + 1;
                }
                col = 0;
                row += 1;
            }
        }
    }
    // Cursor at end of input
    input.chars().count()
}

fn draw(f: &mut Frame, app: &App) {
    let total_h = f.size().height;
    let full_w = f.size().width as usize;
    let input_inner_w = full_w.saturating_sub(2); // input box keeps borders

    // Pre-wrap input text (character-based, matches cursor_xy exactly)
    let wrapped = wrap_input(&app.input, input_inner_w);
    let text_lines = wrapped.len();

    // Input box grows with content, capped at half the screen
    let max_input_h = (total_h / 2).max(3);
    let input_h = ((text_lines as u16) + 2).min(max_input_h).max(3);

    // Title bar (1 line) + top pane + input box
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Min(1),
            Constraint::Length(input_h),
        ])
        .split(f.size());

    // Title bar — inverted (white on dark) full-width bar
    let title_text = if app.quit_armed.is_some() {
        format!("{}— press ctrl+c again to quit ", app.mode_title())
    } else {
        app.mode_title()
    };
    let bar_width = chunks[0].width as usize;
    let padded = format!("{:<width$}", title_text, width = bar_width);
    let title = Line::from(Span::styled(
        padded,
        Style::default()
            .fg(Color::White)
            .bg(Color::DarkGray)
            .add_modifier(Modifier::BOLD),
    ));
    f.render_widget(Paragraph::new(title), chunks[0]);

    // Top pane (no borders): render based on mode
    match app.mode {
        Mode::Chat => {
            let msg_lines: Vec<Line> = app
                .messages
                .iter()
                .map(|m| {
                    let color = if m.is_agent {
                        Color::Green
                    } else {
                        Color::Blue
                    };
                    Line::from(vec![
                        Span::styled(format!("{}: ", m.sender), Style::default().fg(color).bold()),
                        Span::raw(&m.content),
                    ])
                })
                .collect();

            let para = Paragraph::new(msg_lines).wrap(Wrap { trim: false });
            let msg_inner_h = chunks[1].height as usize;
            let total = para.line_count(chunks[1].width);
            let max_scroll = total.saturating_sub(msg_inner_h);
            let scroll = max_scroll.saturating_sub(app.scroll_offset) as u16;

            let messages = para.scroll((scroll, 0));
            f.render_widget(messages, chunks[1]);
        }
        Mode::Thinkers | Mode::Traj | Mode::Command => {
            let output_lines: Vec<Line> =
                app.cmd_output.iter().map(|l| parse_ansi_line(l)).collect();

            let para = Paragraph::new(output_lines).wrap(Wrap { trim: false });
            let msg_inner_h = chunks[1].height as usize;
            let total = para.line_count(chunks[1].width);
            let max_scroll = total.saturating_sub(msg_inner_h);
            let scroll = max_scroll.saturating_sub(app.cmd_scroll) as u16;

            let output = para.scroll((scroll, 0));
            f.render_widget(output, chunks[1]);
        }
    }

    // Input area — render pre-wrapped lines (no ratatui Wrap, so cursor matches exactly)
    let (cx, cy) = cursor_xy(&app.input, app.cursor, input_inner_w);
    let visible_lines = input_h.saturating_sub(2);
    let input_scroll = if cy >= visible_lines {
        cy - visible_lines + 1
    } else {
        0
    };

    let input_text: Vec<Line> = if app.input.is_empty() && app.refresh_paused {
        vec![Line::from(Span::styled(
            "press enter to return to the live view",
            Style::default().fg(Color::DarkGray),
        ))]
    } else {
        wrapped.iter().map(|l| Line::from(l.as_str())).collect()
    };
    let input = Paragraph::new(input_text)
        .block(Block::default().borders(Borders::ALL).title(" > "))
        .scroll((input_scroll, 0));
    f.render_widget(input, chunks[2]);

    f.set_cursor(chunks[2].x + 1 + cx, chunks[2].y + 1 + cy - input_scroll);
}
