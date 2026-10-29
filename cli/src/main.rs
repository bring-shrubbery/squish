use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

use squish_cli::clean::{self, CleanOptions, Selectors};
use squish_cli::git::ProcessGit;
use squish_cli::report::{self, ScanOptions, SortKey};
use squish_cli::style::{self, ColorChoice, Paint, Progress};
use squish_cli::worktree::Thresholds;

/// Find the git worktrees your coding agents left behind, and clean them up safely.
///
/// squish looks for git repos under a folder, lists their linked worktrees with their size,
/// last activity and any work that exists only there, and removes the ones you choose with
/// `git worktree remove`, keeping their branches.
#[derive(Parser)]
#[command(name = "squish", version, about, long_about, max_term_width = 100)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    /// When to use colours.
    #[arg(long, global = true, value_enum, default_value_t = ColorChoice::Auto)]
    color: ColorChoice,
}

#[derive(Subcommand)]
enum Command {
    /// List the linked worktrees under a folder: size, last activity, uncommitted and unpushed
    /// work, and which are stale or large. The default command.
    #[command(visible_alias = "a")]
    Analyze(AnalyzeArgs),
    /// Remove worktrees: pick them interactively, or choose them with --flagged, --stale,
    /// --large, --missing or --all. Shows what each removal does and asks first.
    #[command(visible_alias = "c")]
    Clean(CleanArgs),
}

#[derive(Args, Clone)]
struct ScanArgs {
    /// The folder to search for repos; a folder inside a repo finds that repo too.
    #[arg(default_value = ".")]
    path: PathBuf,

    /// How many folder levels below PATH to look for repos.
    #[arg(long, value_name = "LEVELS", default_value_t = 4)]
    depth: usize,

    /// Flag worktrees with no commit or index change in more than this many days.
    #[arg(long, value_name = "DAYS", default_value_t = Thresholds::default().max_age_days)]
    stale_after: u64,

    /// Flag worktrees taking more disk than this, such as 500MB or 2GB.
    #[arg(long, value_name = "SIZE", default_value = "1GB", value_parser = style::parse_bytes)]
    large_over: u64,

    /// Don't measure sizes; faster on big trees.
    #[arg(long)]
    no_size: bool,
}

#[derive(Args, Clone)]
struct AnalyzeArgs {
    #[command(flatten)]
    scan: ScanArgs,

    /// Show only worktrees past the stale or size threshold.
    #[arg(long)]
    flagged: bool,

    /// Order within each repo.
    #[arg(long, value_enum, default_value_t = SortKey::Size)]
    sort: SortKey,

    /// Print JSON instead of a table.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
struct CleanArgs {
    #[command(flatten)]
    scan: ScanArgs,

    /// Remove worktrees past the stale or size threshold.
    #[arg(long, help_heading = "Choose")]
    flagged: bool,

    /// Remove worktrees idle past --stale-after.
    #[arg(long, help_heading = "Choose")]
    stale: bool,

    /// Remove worktrees larger than --large-over.
    #[arg(long, help_heading = "Choose")]
    large: bool,

    /// Prune worktrees whose directory is already gone.
    #[arg(long, help_heading = "Choose")]
    missing: bool,

    /// Remove every linked worktree that is not in use or locked.
    #[arg(long, help_heading = "Choose")]
    all: bool,

    /// Show what would be removed, and remove nothing.
    #[arg(short = 'n', long)]
    dry_run: bool,

    /// Don't ask before removing clean worktrees.
    #[arg(short, long)]
    yes: bool,

    /// Also remove worktrees with uncommitted changes or unpushed commits without asking.
    /// Detached commits are saved on a squish/rescued-… branch first.
    #[arg(long)]
    force: bool,
}

impl ScanArgs {
    fn options(&self) -> ScanOptions {
        ScanOptions {
            root: self.path.clone(),
            depth: self.depth,
            measure: !self.no_size,
            thresholds: Thresholds { max_age_days: self.stale_after, max_size_bytes: self.large_over },
        }
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let paint = Paint::new(cli.color);
    let git = ProcessGit::default();
    let command = cli.command.unwrap_or_else(|| {
        Command::Analyze(AnalyzeArgs::from_scan(ScanArgs {
            path: PathBuf::from("."),
            depth: 4,
            stale_after: Thresholds::default().max_age_days,
            large_over: Thresholds::default().max_size_bytes,
            no_size: false,
        }))
    });

    let scan = match &command {
        Command::Analyze(args) => &args.scan,
        Command::Clean(args) => &args.scan,
    };
    if !scan.path.is_dir() {
        eprintln!("squish: {} is not a folder", scan.path.display());
        return ExitCode::from(2);
    }
    let options = scan.options();
    let json = matches!(&command, Command::Analyze(args) if args.json);
    let progress = Progress::new(!json);
    let report = match report::collect(&git, &options, &progress) {
        Ok(report) => report,
        Err(error) => {
            progress.clear();
            eprintln!("squish: {error}");
            return ExitCode::from(1);
        }
    };

    match command {
        Command::Analyze(args) => {
            if args.json {
                report::print_json(&report, args.sort, args.flagged, options.measure);
            } else {
                report::print_text(&report, args.sort, args.flagged, &paint, options.measure);
            }
            ExitCode::SUCCESS
        }
        Command::Clean(args) => {
            let options = CleanOptions {
                selectors: Selectors {
                    flagged: args.flagged,
                    stale: args.stale,
                    large: args.large,
                    missing: args.missing,
                    all: args.all,
                },
                dry_run: args.dry_run,
                yes: args.yes,
                force: args.force,
                measured: options.measure,
            };
            ExitCode::from(clean::run(&git, report, &options, &paint) as u8)
        }
    }
}

impl AnalyzeArgs {
    fn from_scan(scan: ScanArgs) -> AnalyzeArgs {
        AnalyzeArgs { scan, flagged: false, sort: SortKey::Size, json: false }
    }
}
