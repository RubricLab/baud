//! `peer-node bench`: the latency table, this machine against a remote one over ssh. Every node
//! is fresh and scratch: local ones under `--scratch`, remote ones under `~/peer-bench` on the
//! remote, started detached (`tail -f in | peer-node … > out`) so an ssh drop does not kill them,
//! and stopped by the pid their own `open` trace line names. Nothing else on the remote is
//! touched. Timings come from the crate's trace lines (monotonic, measured inside the node);
//! the two cross-machine numbers (relaunch) are measured on this machine's clock and include
//! one ssh hop. `scripts/bench.sh` builds, copies the binary and appends the table to
//! target/bench.md.

use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::mpsc;

type Res<T> = Result<T, Box<dyn std::error::Error>>;

pub struct BenchOpts {
    pub remote: String,
    pub runs: usize,
    pub only: Vec<String>,
    pub wake_secs: u64,
    pub blob_mb: u64,
    pub out: Option<PathBuf>,
    pub scratch: PathBuf,
    pub relay_port: u16,
    pub public_relays: bool,
}

struct Ssh {
    host: String,
    control: String,
    home: String,
}

impl Ssh {
    /// One master connection for the whole run, detached from our stdio, so every command after
    /// it costs a round trip instead of a handshake.
    async fn connect(host: &str) -> Res<Ssh> {
        let control = format!("{}/pb-%n", std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into()).trim_end_matches('/'));
        let mut ssh = Ssh { host: host.to_owned(), control, home: String::new() };
        let _ = Command::new("ssh")
            .args(["-o", "ControlMaster=yes", "-o", &format!("ControlPath={}", ssh.control), "-o", "ControlPersist=yes", "-o", "ServerAliveInterval=5", "-o", "ConnectTimeout=10", "-fN", host])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await?;
        ssh.home = ssh.run("echo $HOME").await?;
        Ok(ssh)
    }

    fn cmd(&self) -> Command {
        let mut c = Command::new("ssh");
        c.args(["-T", "-o", "ControlMaster=no", "-o", &format!("ControlPath={}", self.control), "-o", "ServerAliveInterval=5", "-o", "ConnectTimeout=10", &self.host]);
        c.stdin(Stdio::null()).stderr(Stdio::null());
        c
    }

    async fn run(&self, script: &str) -> Res<String> {
        let out = self.cmd().arg(script).stderr(Stdio::piped()).output().await?;
        if !out.status.success() {
            return Err(format!("ssh {script}: {}", String::from_utf8_lossy(&out.stderr)).into());
        }
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
    }

    async fn close(&self) {
        let _ = Command::new("ssh").args(["-o", &format!("ControlPath={}", self.control), "-O", "exit", &self.host]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().await;
    }

    fn bin(&self) -> String {
        format!("{}/peer-bench/peer-node", self.home)
    }
}

fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// One peer-node under test: local (a child with pipes) or remote (detached, read by `tail -F`).
struct Node {
    name: &'static str,
    dir: String,
    args: Vec<String>,
    ssh: Option<Arc<Ssh>>,
    launches: usize,
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    tx: mpsc::UnboundedSender<(Instant, String)>,
    rx: mpsc::UnboundedReceiver<(Instant, String)>,
    stop_reader: Arc<AtomicBool>,
    pid: Option<u32>,
    device: String,
    /// `ms` of this launch's `open` line.
    last_open: Option<f64>,
    transcript: Arc<std::sync::Mutex<std::fs::File>>,
}

/// Flags for a node nobody can dial: no gateway mapping, no VPN address, no LAN discovery.
const QUIET: [&str; 3] = ["--no-nearby", "--no-portmap", "--no-vpn"];

fn trace_of(line: &str) -> Option<Value> {
    if line.starts_with('{') { serde_json::from_str(line).ok() } else { None }
}

fn is_ev(line: &str, ev: &str) -> Option<Value> {
    trace_of(line).filter(|v| v["ev"] == ev)
}

impl Node {
    fn new(name: &'static str, dir: String, args: &[&str], ssh: Option<Arc<Ssh>>, scratch: &std::path::Path) -> Res<Node> {
        let (tx, rx) = mpsc::unbounded_channel();
        let transcript = std::fs::OpenOptions::new().create(true).append(true).open(scratch.join(format!("{name}.transcript")))?;
        Ok(Node {
            name,
            dir,
            args: args.iter().map(|s| s.to_string()).collect(),
            ssh,
            launches: 0,
            child: None,
            stdin: None,
            tx,
            rx,
            stop_reader: Arc::new(AtomicBool::new(false)),
            pid: None,
            device: String::new(),
            last_open: None,
            transcript: Arc::new(std::sync::Mutex::new(transcript)),
        })
    }

    /// Start (or restart) on the same dir; returns when it says `online as`.
    async fn launch(&mut self) -> Res<Instant> {
        self.launches += 1;
        self.stop_reader = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::unbounded_channel();
        self.tx = tx;
        self.rx = rx;
        let started = Instant::now();
        match self.ssh.clone() {
            None => {
                std::fs::create_dir_all(&self.dir)?;
                let err = std::fs::File::create(format!("{}/err.{}", self.dir, self.launches))?;
                let mut child = Command::new(std::env::current_exe()?)
                    .arg("--dir")
                    .arg(&self.dir)
                    .arg("run")
                    .args(&self.args)
                    .arg("--trace")
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(err)
                    .kill_on_drop(true)
                    .spawn()?;
                self.stdin = child.stdin.take();
                let out = child.stdout.take().ok_or("no stdout")?;
                let (tx, transcript, name) = (self.tx.clone(), self.transcript.clone(), self.name);
                tokio::spawn(async move {
                    let mut lines = BufReader::new(out).lines();
                    while let Ok(Some(l)) = lines.next_line().await {
                        let _ = std::io::Write::write_all(&mut *transcript.lock().unwrap(), format!("{name} {l}\n").as_bytes());
                        let _ = tx.send((Instant::now(), l));
                    }
                });
                self.child = Some(child);
            }
            Some(ssh) => {
                let (d, g) = (&self.dir, self.launches);
                let args: Vec<String> = self.args.iter().map(|a| quote(a)).collect();
                ssh.run(&format!(
                    "mkdir -p {d} && : > {d}/in.{g} && (nohup sh -c \"tail -n +1 -f {d}/in.{g} | {bin} --dir {d} run {args} --trace > {d}/out.{g} 2> {d}/err.{g}\" > /dev/null 2>&1 &)",
                    bin = ssh.bin(),
                    args = args.join(" ")
                ))
                .await?;
                let (tx, stop, transcript, name, path) = (self.tx.clone(), self.stop_reader.clone(), self.transcript.clone(), self.name, format!("{d}/out.{g}"));
                tokio::spawn(async move {
                    let mut seen = 0usize;
                    while !stop.load(Ordering::SeqCst) {
                        let Ok(mut child) = ssh.cmd().arg(format!("exec tail -n +{} -F {path} 2>/dev/null", seen + 1)).stdout(Stdio::piped()).kill_on_drop(true).spawn() else {
                            tokio::time::sleep(Duration::from_secs(1)).await;
                            continue;
                        };
                        let Some(out) = child.stdout.take() else { break };
                        let mut lines = BufReader::new(out).lines();
                        loop {
                            tokio::select! {
                                l = lines.next_line() => match l {
                                    Ok(Some(l)) => {
                                        seen += 1;
                                        let _ = std::io::Write::write_all(&mut *transcript.lock().unwrap(), format!("{name} {l}\n").as_bytes());
                                        let _ = tx.send((Instant::now(), l));
                                    }
                                    _ => break,
                                },
                                _ = tokio::time::sleep(Duration::from_millis(500)) => if stop.load(Ordering::SeqCst) { break },
                            }
                        }
                        let _ = child.kill().await;
                        if !stop.load(Ordering::SeqCst) {
                            tokio::time::sleep(Duration::from_secs(1)).await;
                        }
                    }
                });
            }
        }
        let open = self.wait(|l| is_ev(l, "open").is_some(), Duration::from_secs(30)).await.ok_or(format!("{}: no open line", self.name))?;
        self.pid = trace_of(&open.1).and_then(|v| v["pid"].as_u64()).map(|p| p as u32);
        self.last_open = trace_of(&open.1).and_then(|v| v["ms"].as_f64());
        let online = self.wait(|l| l.starts_with("online as"), Duration::from_secs(30)).await.ok_or(format!("{}: never online", self.name))?;
        self.device = online.1.split(" · device ").nth(1).and_then(|r| r.split(' ').next()).unwrap_or_default().to_owned();
        Ok(started)
    }

    async fn send(&mut self, cmd: &str) -> Res<()> {
        let _ = std::io::Write::write_all(&mut *self.transcript.lock().unwrap(), format!("{} > {cmd}\n", self.name).as_bytes());
        match &self.ssh {
            None => {
                let stdin = self.stdin.as_mut().ok_or("not running")?;
                stdin.write_all(format!("{cmd}\n").as_bytes()).await?;
                stdin.flush().await?;
            }
            Some(ssh) => {
                ssh.run(&format!("printf '%s\\n' {} >> {}/in.{}", quote(cmd), self.dir, self.launches)).await?;
            }
        }
        Ok(())
    }

    /// The next line matching `pred`, skipping the rest, within `timeout`.
    async fn wait(&mut self, pred: impl Fn(&str) -> bool, timeout: Duration) -> Option<(Instant, String)> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            match tokio::time::timeout_at(deadline, self.rx.recv()).await {
                Ok(Some((at, l))) if pred(&l) => return Some((at, l)),
                Ok(Some(_)) => continue,
                _ => return None,
            }
        }
    }

    /// The next trace line of kind `ev` (about `device`, when given).
    async fn wait_ev(&mut self, ev: &str, device: Option<&str>, timeout: Duration) -> Option<(Instant, Value)> {
        let dev = device.map(str::to_owned);
        let ev = ev.to_owned();
        let (at, l) = self.wait(move |l| is_ev(l, &ev).is_some_and(|v| dev.as_deref().is_none_or(|d| v["device"] == d)), timeout).await?;
        Some((at, trace_of(&l)?))
    }

    fn drain(&mut self) {
        while self.rx.try_recv().is_ok() {}
    }

    /// Every line that arrived since the last read, without waiting.
    fn take_lines(&mut self) -> Vec<String> {
        let mut v = Vec::new();
        while let Ok((_, l)) = self.rx.try_recv() {
            v.push(l);
        }
        v
    }

    /// `quit`, and wait for the process to be gone.
    async fn stop(&mut self) -> Res<()> {
        let _ = self.send("quit").await;
        match &self.ssh {
            None => {
                if let Some(mut c) = self.child.take() {
                    if tokio::time::timeout(Duration::from_secs(8), c.wait()).await.is_err() {
                        let _ = c.kill().await;
                    }
                }
            }
            Some(ssh) => {
                if let Some(pid) = self.pid {
                    let _ = ssh.run(&format!("for i in $(seq 1 160); do kill -0 {pid} 2>/dev/null || break; sleep 0.05; done; kill -9 {pid} 2>/dev/null; pkill -f '{}/in.{}' ; true", self.dir, self.launches)).await;
                }
                self.stop_reader.store(true, Ordering::SeqCst);
            }
        }
        self.pid = None;
        Ok(())
    }

    /// No goodbye: what a crash, a force quit or iOS killing a suspended app looks like.
    async fn kill9(&mut self) -> Res<()> {
        match &self.ssh {
            None => {
                if let Some(mut c) = self.child.take() {
                    let _ = c.kill().await;
                }
            }
            Some(ssh) => {
                if let Some(pid) = self.pid {
                    ssh.run(&format!("kill -9 {pid}; pkill -f '{}/in.{}'; true", self.dir, self.launches)).await?;
                }
                self.stop_reader.store(true, Ordering::SeqCst);
            }
        }
        self.pid = None;
        Ok(())
    }

    fn signal(&self, sig: &str) -> Res<()> {
        let pid = self.pid.ok_or("no pid")?;
        std::process::Command::new("kill").arg(format!("-{sig}")).arg(pid.to_string()).status()?;
        Ok(())
    }
}


/// One row of the table. Failures are runs that timed out; they count against the row.
struct Row {
    section: u8,
    scenario: String,
    samples: Vec<f64>,
    unit: &'static str,
    path: String,
    /// The bar, in the sample's unit; `higher` when bigger is better (throughput).
    target: Option<f64>,
    target_text: String,
    higher: bool,
    failures: usize,
    /// What a failure waited for, in the row's unit.
    timeout: f64,
    note: String,
}

fn pct(sorted: &[f64], p: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = ((p / 100.0) * sorted.len() as f64).ceil() as usize;
    Some(sorted[rank.clamp(1, sorted.len()) - 1])
}

const LOOP: u8 = 0;
const DATA: u8 = 1;

impl Row {
    fn new(section: u8, scenario: &str, unit: &'static str, target: f64, target_text: &str) -> Row {
        Row { section, scenario: scenario.into(), samples: Vec::new(), unit, path: String::new(), target: Some(target), target_text: target_text.into(), higher: false, failures: 0, timeout: 0.0, note: String::new() }
    }
    fn sorted(&self) -> Vec<f64> {
        let mut v = self.samples.clone();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v
    }
    fn fmt(&self, v: Option<f64>) -> String {
        match v {
            None => "–".into(),
            Some(v) if self.unit == "ms" && v >= 10_000.0 => format!("{:.1} s", v / 1000.0),
            Some(v) if self.unit == "ms" => format!("{v:.0} ms"),
            Some(v) => format!("{v:.1} {}", self.unit),
        }
    }
    fn verdict(&self) -> &'static str {
        let s = self.sorted();
        if self.failures > 0 || s.is_empty() {
            return "FAIL";
        }
        match self.target {
            None => "",
            Some(t) if self.higher => {
                if pct(&s, 50.0).unwrap() >= t {
                    "pass"
                } else {
                    "FAIL"
                }
            }
            Some(t) => {
                if pct(&s, 95.0).unwrap() <= t {
                    "pass"
                } else {
                    "FAIL"
                }
            }
        }
    }
    fn line(&self) -> String {
        let s = self.sorted();
        // A timed-out run is worse than any sample: p50 and p95 count it at its timeout.
        let mut all = s.clone();
        all.extend(std::iter::repeat_n(f64::INFINITY, self.failures));
        let cell = |p: f64| match pct(&all, p) {
            Some(v) if v.is_infinite() => format!("> {}", self.fmt(Some(self.timeout))),
            v => self.fmt(v),
        };
        let n = if self.failures > 0 { format!("{} ({} timed out)", all.len(), self.failures) } else { s.len().to_string() };
        format!("| {} | {} | {} | {} | {} | {} | {} |{}", self.scenario, n, cell(50.0), cell(95.0), self.path, self.target_text, self.verdict(), if self.note.is_empty() { String::new() } else { format!(" {}", self.note) })
    }
    fn took(&mut self, v: Option<f64>, path: &str) {
        match v {
            Some(v) => {
                self.samples.push(v);
                note_path(self, path);
            }
            None => self.failures += 1,
        }
    }
}

fn path_of(v: &Value) -> String {
    v["path"].as_str().map(|p| if p.starts_with("relayed by") { "relayed".to_owned() } else { p.to_owned() }).unwrap_or_default()
}

fn note_path(row: &mut Row, p: &str) {
    if p.is_empty() {
        return;
    }
    if row.path.is_empty() {
        row.path = p.to_owned();
    } else if !row.path.split(", ").any(|x| x == p) {
        row.path = format!("{}, {p}", row.path);
    }
}

fn median(v: &[f64]) -> Option<f64> {
    let mut v = v.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    pct(&v, 50.0)
}

fn ms_since(t0: Instant, at: Instant) -> f64 {
    at.saturating_duration_since(t0).as_millis() as f64
}

/// How long a run waits before it counts as a failure.
const SLOW: Duration = Duration::from_secs(40);

struct Bench {
    o: BenchOpts,
    ssh: Arc<Ssh>,
    rows: Vec<Row>,
    rtts: Vec<f64>,
    /// Every remote launch, for cleanup: (dir, pid).
    launched: Vec<(String, Option<u32>)>,
    notes: Vec<String>,
}

pub async fn run(o: BenchOpts) -> Res<bool> {
    std::fs::create_dir_all(&o.scratch)?;
    let ssh = Arc::new(Ssh::connect(&o.remote).await?);
    ssh.run(&format!("test -x {}", ssh.bin())).await.map_err(|_| format!("no {} on {}: run scripts/bench.sh, which copies it", ssh.bin(), o.remote))?;
    let mut b = Bench { o, ssh: ssh.clone(), rows: Vec::new(), rtts: Vec::new(), launched: Vec::new(), notes: Vec::new() };
    let result = b.all().await;
    b.cleanup().await;
    ssh.close().await;
    if let Err(e) = &result {
        b.notes.push(format!("bench stopped early: {e}"));
    }
    let table = b.table();
    println!("{table}");
    if let Some(out) = &b.o.out {
        std::fs::write(out, &table)?;
    }
    Ok(result.is_ok())
}

impl Bench {
    fn wants(&self, s: &str) -> bool {
        if self.o.only.is_empty() { s != "ipchange" } else { self.o.only.iter().any(|x| x == s) }
    }

    fn remote_dir(&self, n: &str) -> String {
        format!("{}/peer-bench/{n}", self.ssh.home)
    }

    fn local_dir(&self, n: &str) -> String {
        self.o.scratch.join(n).to_string_lossy().into_owned()
    }

    fn remote(&self, name: &'static str, dir: &str, args: &[&str]) -> Res<Node> {
        Node::new(name, self.remote_dir(dir), args, Some(self.ssh.clone()), &self.o.scratch)
    }

    fn local(&self, name: &'static str, dir: &str, args: &[&str]) -> Res<Node> {
        Node::new(name, self.local_dir(dir), args, None, &self.o.scratch)
    }

    async fn launch(&mut self, n: &mut Node) -> Res<Instant> {
        let t = n.launch().await?;
        if n.ssh.is_some() {
            self.launched.push((format!("{}/in.{}", n.dir, n.launches), n.pid));
        }
        Ok(t)
    }

    async fn cleanup(&mut self) {
        let mut script = String::new();
        for (_, pid) in &self.launched {
            if let Some(pid) = pid {
                script.push_str(&format!("kill {pid} 2>/dev/null; "));
            }
        }
        script.push_str("sleep 0.5; pkill -f 'peer-bench/[a-z0-9]+/(in|out)\\.'; true");
        let _ = self.ssh.run(&script).await;
    }

    fn table(&self) -> String {
        let mut t = String::from("| scenario | n | p50 | p95 | path | target | |\n|---|---|---|---|---|---|---|\n");
        let mut rows: Vec<&Row> = self.rows.iter().collect();
        rows.sort_by_key(|r| r.section);
        for r in rows {
            t.push_str(&r.line());
            t.push('\n');
        }
        t.push('\n');
        if let Some(rtt) = median(&self.rtts) {
            t.push_str(&format!("RTT (QUIC, direct path) median {rtt:.0} ms. "));
        }
        t.push_str("Pass is p95 within target (p50 for throughput); a timed-out run counts at its timeout. Rows marked † are timed on this machine's clock across one ssh hop.\n");
        for n in &self.notes {
            t.push_str(&format!("\n{n}\n"));
        }
        t
    }

    async fn wait_global_addr(&self, n: &mut Node) {
        // A UPnP mapping takes a moment; an invite made before it names only LAN addresses.
        for _ in 0..40 {
            let _ = n.send("status").await;
            if let Some((_, l)) = n.wait(|l| l.starts_with("addresses:"), Duration::from_secs(5)).await
                && l.split_whitespace().skip(1).any(|a| a.parse::<std::net::SocketAddr>().is_ok_and(|sa| match sa.ip() {
                    std::net::IpAddr::V4(v) => !v.is_private() && !v.is_loopback() && !v.is_link_local() && v.octets()[0] != 100,
                    _ => false,
                }))
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    }

    async fn invite(&self, n: &mut Node, kind: &str) -> Res<String> {
        n.send(kind).await?;
        let prefix = if kind == "invite" { "invite: " } else { "device link: " };
        let (_, l) = n.wait(|l| l.starts_with(prefix), Duration::from_secs(10)).await.ok_or(format!("{}: no {kind}", n.name))?;
        Ok(l.trim_start_matches(prefix).to_owned())
    }

    async fn add(&self, n: &mut Node, link: &str) -> Res<Instant> {
        n.send(&format!("add {link}")).await?;
        let (at, l) = n.wait(|l| l.starts_with("added ") || l.starts_with("error:"), Duration::from_secs(40)).await.ok_or(format!("{}: add timed out", n.name))?;
        if l.starts_with("error:") {
            return Err(format!("{}: add: {l}", n.name).into());
        }
        Ok(at)
    }

    /// Is `device` online to `n`, by `peers`?
    async fn online_rtt(&self, n: &mut Node, device: &str) -> Option<f64> {
        n.send("peers").await.ok()?;
        let d = device.to_owned();
        let (_, l) = n.wait(move |l| l.starts_with(&d), Duration::from_secs(5)).await?;
        if !l.contains(" online ") {
            return None;
        }
        l.split_whitespace().rev().nth(1).and_then(|r| r.parse().ok()).or(Some(0.0))
    }

    /// Make sure `a` holds a connection to `b` before the next scenario: if not, restart `a`
    /// (cache and dial at open), and as a last resort `b` too.
    async fn rejoin(&mut self, a: &mut Node, b: &mut Node) -> Res<()> {
        for _ in 0..3 {
            if self.online_rtt(a, &b.device.clone()).await.is_some() {
                return Ok(());
            }
            a.stop().await?;
            self.launch(a).await?;
            if a.wait_ev("attach", Some(&b.device.clone()), Duration::from_secs(15)).await.is_some() {
                return Ok(());
            }
        }
        Err(format!("{} cannot reach {} again", a.name, b.name).into())
    }

    async fn all(&mut self) -> Res<()> {
        let s = self.ssh.clone();
        let _ = std::fs::remove_dir_all(&self.o.scratch);
        std::fs::create_dir_all(&self.o.scratch)?;
        s.run(&format!("cd {h}/peer-bench && rm -rf m r m2 home f0 f1 f2 f3 f4 fc bob mh mo mf bm rd-b0 rd-c0 rd-e0 rd-b1 rd-c1 rd-e1 rd-b2 rd-c2 rd-e2 rd-b3 rd-c3 rd-e3 rd-b4 rd-c4 rd-e4 big-0.bin big-1.bin", h = s.home)).await?;
        let direct = ["cold", "online", "record", "relaunch", "dead", "wake", "message", "blob", "reimport", "phantom", "ipchange"].iter().any(|x| self.wants(x));
        if direct && let Err(e) = self.direct().await {
            self.notes.push(format!("direct topology stopped: {e}"));
        }
        if self.wants("relayed") && let Err(e) = self.relayed().await {
            self.notes.push(format!("relayed topology stopped: {e}"));
        }
        if self.wants("own") && let Err(e) = self.own().await {
            self.notes.push(format!("own-device topology stopped: {e}"));
        }
        if self.wants("chat") && let Err(e) = self.chat().await {
            self.notes.push(format!("chat topology stopped: {e}"));
        }
        if self.wants("meet") && let Err(e) = self.meet().await {
            self.notes.push(format!("meet topology stopped: {e}"));
        }
        if self.wants("own-relay") && let Err(e) = self.own_relay().await {
            self.notes.push(format!("own-relay topology stopped: {e}"));
        }
        if self.wants("redirect") && let Err(e) = self.redirect().await {
            self.notes.push(format!("redirect topology stopped: {e}"));
        }
        Ok(())
    }

    /// Two baud-shaped nodes with the relay on (no fixed port, the gateway asked for a mapping):
    /// the inviter on the home Mac is its own meeting device, and a friend here adds through its relay.
    /// The relay is offered only on a confirmed mapping (or `--public-relays`): against a gateway
    /// that maps nothing, the inviter says `none`, and the row says so.
    async fn own_relay(&mut self) -> Res<()> {
        let mut args = vec!["--name", "dex", "--relay", "--auto-confirm-links", "--no-nearby"];
        if self.o.public_relays {
            args.push("--public");
        }
        let mut inv = self.remote("baud-mac", "bm", &args)?;
        self.launch(&mut inv).await?;
        let r = async {
            let mut kind = String::new();
            for _ in 0..40 {
                inv.send("meeting").await?;
                if let Some((_, l)) = inv.wait(|l| l.starts_with("meeting: "), Duration::from_secs(5)).await {
                    kind = l.split(' ').nth(1).unwrap_or_default().to_owned();
                    if l.starts_with("meeting: Own ") && l.ends_with(" homed") {
                        break;
                    }
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            let mut row = Row::new(LOOP, "baud-shaped: a relay node is its own meeting device (inviteMeeting own), a friend adds through it", "ms", 5000.0, "5 s");
            row.timeout = 40_000.0;
            if kind != "Own" {
                row.failures += 1;
                row.note = format!("(inviteMeeting on the inviter: {kind}{})", if self.o.public_relays { "" } else { "; the gateway maps nothing, so the relay is not offered" });
                self.rows.push(row);
                return Ok(());
            }
            for i in 0..self.o.runs {
                let link = self.invite(&mut inv, "invite").await?;
                let mut a = self.local("baud-friend", &format!("bf{i}"), &["--name", "ana", "--relay", "--no-nearby", "--no-portmap"])?;
                self.launch(&mut a).await?;
                a.drain();
                let t = Instant::now();
                a.send(&format!("add {link}")).await?;
                let deadline = tokio::time::Instant::now() + Duration::from_secs(40);
                let (mut path, mut done) = (String::new(), None);
                while done.is_none() {
                    let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                    let Some((at, l)) = a.wait(|l| l.starts_with("added ") || l.starts_with("error:") || is_ev(l, "dial").is_some_and(|v| v["why"] == "add"), left).await else { break };
                    match is_ev(&l, "dial") {
                        Some(v) => path = path_of(&v),
                        None => done = Some((at, l)),
                    }
                }
                match done {
                    Some((at, l)) if l.starts_with("added ") => row.took(Some(ms_since(t, at)), &path),
                    _ => row.failures += 1,
                }
                a.stop().await?;
            }
            row.note = format!("(inviteMeeting on the inviter: own{})", if self.o.public_relays { ", relay offered on the LAN (--public-relays)" } else { "" });
            self.rows.push(row);
            Ok::<(), Box<dyn std::error::Error>>(())
        }
        .await;
        let _ = inv.stop().await;
        r
    }

    /// Identity redirect: bob (on the home Mac) is ana's friend (on this laptop); bob's device links
    /// into carl, bob's other identity (also on the home Mac, with a friend of his own, eve). Ana
    /// must end with one contact named as before, reach bob's device under carl, and eve, never
    /// bob's friend, must learn nothing.
    async fn redirect(&mut self) -> Res<()> {
        let mut follow = Row::new(LOOP, "redirect: B links into its other identity C (from the link command) → A has one contact, named as before", "ms", 2000.0, "2 s");
        let mut reach = Row::new(LOOP, "redirect: a message from A reaches B's device under C †", "ms", 2000.0, "2 s");
        let mut leak = Row::new(LOOP, "redirect: a non-contact of B's old identity holds it", "redirects", 0.0, "never");
        for r in [&mut follow, &mut reach] {
            r.timeout = 10_000.0;
        }
        for i in 0..self.o.runs.div_ceil(2).max(1) {
            let mut b = self.remote("rd-bob", &format!("rd-b{i}"), &["--name", "bob", "--no-nearby", "--port", "4171"])?;
            let mut c = self.remote("rd-carl", &format!("rd-c{i}"), &["--name", "carl", "--auto-confirm-links", "--no-nearby", "--port", "4172"])?;
            let mut e = self.remote("rd-eve", &format!("rd-e{i}"), &["--name", "eve", "--no-nearby", "--port", "4173"])?;
            let mut a = self.local("rd-ana", &format!("rd-a{i}"), &["--name", "ana", "--no-nearby"])?;
            let r = async {
                for n in [&mut b, &mut c, &mut e] {
                    self.launch(n).await?;
                }
                self.launch(&mut a).await?;
                let l = self.invite(&mut a, "invite").await?;
                self.add(&mut b, &l).await?;
                let l = self.invite(&mut c, "invite").await?;
                self.add(&mut e, &l).await?;
                let bd = b.device.clone();
                a.wait_ev("attach", Some(&bd), Duration::from_secs(20)).await.ok_or("ana never reached bob")?;
                let link = self.invite(&mut c, "link-device").await?;
                a.drain();
                let t0 = Instant::now();
                b.send(&format!("link {link}")).await?;
                let got = a.wait_ev("redirected", None, Duration::from_secs(10)).await;
                a.send("contacts").await?;
                tokio::time::sleep(Duration::from_millis(300)).await;
                let contacts: Vec<String> = a.take_lines().into_iter().filter(|l| !l.starts_with('{') && !l.starts_with('·') && l.contains(" devices ")).collect();
                match got {
                    Some((at, _)) if contacts.len() == 1 && contacts[0].starts_with("bob ") => follow.took(Some(ms_since(t0, at)), ""),
                    Some(_) => {
                        follow.failures += 1;
                        follow.note = format!("(ana's contacts after: {contacts:?})");
                    }
                    None => follow.failures += 1,
                }
                b.wait(|l| l.starts_with("linked:") || l.starts_with("error:"), Duration::from_secs(30)).await;
                b.drain();
                let t = Instant::now();
                a.send("post bob still me?").await?;
                let got = b.wait(|l| l.starts_with("· inbox "), Duration::from_secs(10)).await;
                reach.took(got.map(|(at, _)| ms_since(t, at)), "");
                e.drain();
                e.send("redirects").await?;
                let (_, l) = e.wait(|l| l.ends_with(" redirects"), Duration::from_secs(5)).await.ok_or("eve: no redirects line")?;
                leak.samples.push(l.split(' ').next().and_then(|n| n.parse().ok()).unwrap_or(f64::NAN));
                Ok::<(), Box<dyn std::error::Error>>(())
            }
            .await;
            for n in [&mut a, &mut b, &mut c, &mut e] {
                let _ = n.stop().await;
            }
            if let Err(err) = r {
                self.rows.extend([follow, reach, leak]);
                return Err(err);
            }
        }
        self.rows.extend([follow, reach, leak]);
        Ok(())
    }

    /// Two nodes nobody can dial (no port mapping, no VPN: two phones on cellular, as far as the
    /// lab can say) meet through a third that runs a relay on the home Mac: first the inviter's own
    /// device, then a friend's. Each run's redeemer is a fresh node on this laptop, a stranger
    /// to the helper; its link names only the helper's relay, with the inviter's meet token.
    async fn meet(&mut self) -> Res<()> {
        let mut args = vec!["--name", "helen", "--relay", "--auto-confirm-links", "--no-nearby", "--port", "4151"];
        if self.o.public_relays {
            args.push("--public");
        }
        let mut h = self.remote("helper", "mh", &args)?;
        self.launch(&mut h).await?;
        let r = self.meet_topology(&mut h).await;
        let _ = h.stop().await;
        r
    }

    async fn meet_topology(&mut self, h: &mut Node) -> Res<()> {
        h.send("status").await?;
        let (_, l) = h.wait(|l| l.starts_with("relay: "), Duration::from_secs(10)).await.ok_or("helper status")?;
        if l.contains("none") {
            return Err("the helper's relay was not offered (no TCP mapping)".into());
        }
        let quiet = QUIET;
        // The helper's own device: links to it.
        let mut own = self.remote("meet-own", "mo", &[&["--name", "throwaway", "--port", "4152"][..], &quiet].concat())?;
        let link = self.invite(h, "link-device").await?;
        self.launch(&mut own).await?;
        own.send(&format!("link {link}")).await?;
        own.wait(|l| l.starts_with("linked:") || l.starts_with("error:"), Duration::from_secs(40)).await.filter(|(_, l)| l.starts_with("linked:")).ok_or("meet-own could not link to the helper")?;
        let r = self.meet_rows(&mut own, h, "Own", "the home Mac, the inviter's own device").await;
        let _ = own.stop().await;
        r?;
        // The helper's friend: adds the helper's invite (which names the helper itself).
        let mut friend = self.remote("meet-friend", "mf", &[&["--name", "bob", "--port", "4153"][..], &quiet].concat())?;
        self.launch(&mut friend).await?;
        let l = self.invite(h, "invite").await?;
        self.add(&mut friend, &l).await?;
        let r = self.meet_rows(&mut friend, h, "Friend", "the home Mac as the inviter's friend's device (the redeemer holds no card for it)").await;
        let _ = friend.stop().await;
        r
    }

    async fn meet_rows(&mut self, inviter: &mut Node, h: &mut Node, kind: &str, through: &str) -> Res<()> {
        // A link reaches the inviter only once it is homed on the helper's relay.
        let mut homed = false;
        for _ in 0..60 {
            inviter.send("meeting").await?;
            if inviter.wait(|l| l.starts_with("meeting: "), Duration::from_secs(5)).await.is_some_and(|(_, l)| l.starts_with(&format!("meeting: {kind} ")) && l.ends_with(" homed")) {
                homed = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        if !homed {
            return Err(format!("{}: never homed on the helper as its {kind} meeting device", inviter.name).into());
        }
        let mut row = Row::new(LOOP, &format!("no-portmap A adds no-portmap B through {through}"), "ms", 5000.0, "5 s");
        row.timeout = 40_000.0;
        let mut leak = Row::new(LOOP, "the helper holds the redeemer's card or record (it relays ciphertext only)", "records", 0.0, "never");
        let mut relayed = 0;
        for i in 0..self.o.runs {
            let link = self.invite(inviter, "invite").await?;
            let addrs = peer::link::parse(&link).map(|l| l.meet.addrs).unwrap_or_default();
            if addrs.is_empty() || addrs.iter().any(|a| !(a.starts_with("relay=") && a.contains("?m="))) {
                row.note = "(a link carried a raw address)".into();
            }
            let mut a = self.local("redeemer", &format!("ma{}{i}", kind.to_lowercase()), &[&["--name", "ana"][..], &QUIET].concat())?;
            self.launch(&mut a).await?;
            a.drain();
            let t = Instant::now();
            a.send(&format!("add {link}")).await?;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(40);
            let (mut path, mut done) = (String::new(), None);
            while done.is_none() {
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                let Some((at, l)) = a.wait(|l| l.starts_with("added ") || l.starts_with("error:") || is_ev(l, "dial").is_some_and(|v| v["why"] == "add"), left).await else { break };
                match is_ev(&l, "dial") {
                    Some(v) => path = path_of(&v),
                    None => done = Some((at, l)),
                }
            }
            match done {
                Some((at, l)) if l.starts_with("added ") => row.took(Some(ms_since(t, at)), &path),
                _ => row.failures += 1,
            }
            if kind == "Friend" {
                tokio::time::sleep(Duration::from_millis(500)).await;
                let ad = a.device.clone();
                h.drain();
                h.send("records").await?;
                h.send("contacts").await?;
                h.send("trace").await?;
                tokio::time::sleep(Duration::from_millis(500)).await;
                let lines = h.take_lines();
                // Its records and contacts (not the trace, which names the client it admitted).
                leak.samples.push(lines.iter().filter(|l| !l.starts_with('{') && l.contains(ad.as_str())).count() as f64);
                relayed += lines.iter().filter_map(|l| is_ev(l, "meet")).filter(|v| v["client"] == ad.as_str()).count().min(1);
            }
            a.stop().await?;
        }
        if kind == "Friend" {
            leak.note = format!("(the helper's relay admitted the redeemer by token in {relayed} of {} runs)", self.o.runs);
            self.rows.extend([row, leak]);
        } else {
            self.rows.push(row);
        }
        Ok(())
    }

    /// Three tiers, a chat: ana and carol (both on this laptop) are each friends with bob on the
    /// mini and not with each other; bob makes a chat of the three. What ana sends carol must
    /// arrive carried by bob, and neither may ever hold the other's address record.
    async fn chat(&mut self) -> Res<()> {
        let mut bob = self.remote("bob", "bob", &["--name", "bob", "--no-nearby", "--port", "4127"])?;
        let mut ana = self.local("ana", "ca", &["--name", "ana", "--no-nearby"])?;
        let mut carol = self.local("carol", "cc", &["--name", "carol", "--no-nearby"])?;
        self.launch(&mut bob).await?;
        let r = self.chat_runs(&mut bob, &mut ana, &mut carol).await;
        let _ = ana.stop().await;
        let _ = carol.stop().await;
        let _ = bob.stop().await;
        r
    }

    async fn chat_runs(&mut self, bob: &mut Node, ana: &mut Node, carol: &mut Node) -> Res<()> {
        let (l1, l2) = (self.invite(bob, "invite").await?, self.invite(bob, "invite").await?);
        self.launch(ana).await?;
        self.add(ana, &l1).await?;
        self.launch(carol).await?;
        self.add(carol, &l2).await?;
        let bd = bob.device.clone();
        for n in [&mut *ana, &mut *carol] {
            if self.online_rtt(n, &bd).await.is_none() {
                n.wait_ev("attach", Some(&bd), Duration::from_secs(20)).await.ok_or("not connected to bob")?;
            }
        }
        bob.send("group-new chat").await?;
        let (_, l) = bob.wait(|l| l.starts_with("group "), Duration::from_secs(10)).await.ok_or("no group")?;
        let gid = l.split_whitespace().nth(1).unwrap_or_default().to_owned();
        for n in [&mut *ana, &mut *carol] {
            n.send(&format!("group {gid} chat")).await?;
            n.wait(|l| l.starts_with("in group"), Duration::from_secs(10)).await.ok_or("could not join the group")?;
            // Each member's own group event names who invited them: bob.
            n.send(&format!("group-add {gid} bob")).await?;
            n.wait(|l| l.starts_with("added bob"), Duration::from_secs(10)).await.ok_or("could not add bob to the group")?;
        }
        for name in ["ana", "carol"] {
            bob.send(&format!("group-add {gid} {name}")).await?;
            bob.wait(|l| l.starts_with("added ") || l.starts_with("error:"), Duration::from_secs(10)).await.filter(|(_, l)| l.starts_with("added ")).ok_or(format!("bob could not add {name}"))?;
        }
        // The cards travel through bob: ana learns carol's (public name, not a contact).
        let mut knows = false;
        for _ in 0..40 {
            ana.send(&format!("members {gid}")).await?;
            if ana.wait(|l| l.starts_with("member carol"), Duration::from_secs(1)).await.is_some() {
                knows = true;
                break;
            }
        }
        if !knows {
            return Err("ana never learned carol's card from the chat".into());
        }
        let mut msg = Row::new(LOOP, "chat: message to a co-member who is not a contact, carried by a shared friend", "ms", 2000.0, "2 s");
        msg.timeout = 20_000.0;
        for i in 0..self.o.runs {
            carol.drain();
            let t0 = Instant::now();
            ana.send(&format!("gpost {gid} carol chat {i}")).await?;
            let got = carol.wait_ev("inbox", None, Duration::from_secs(20)).await;
            msg.took(got.as_ref().map(|(at, _)| ms_since(t0, *at)), got.as_ref().and_then(|(_, v)| v["via"].as_str()).unwrap_or(""));
        }
        // The privacy assertion: neither holds the other's record, neither is connected to the other.
        tokio::time::sleep(Duration::from_secs(2)).await;
        let mut leak = Row::new(LOOP, "chat: co-members who are not contacts hold each other's record", "records", 0.0, "never");
        let (ad, cd) = (ana.device.clone(), carol.device.clone());
        let mut leaks = 0.0;
        for (n, other) in [(&mut *ana, cd.clone()), (&mut *carol, ad.clone())] {
            n.drain();
            n.send("records").await?;
            n.send("peers").await?;
            n.send("status").await?;
            // `status` ends with the inbox line: everything before it is the listings.
            let mut seen = false;
            while let Some((_, l)) = n.wait(|_| true, Duration::from_secs(5)).await {
                if l.starts_with(&other) || (l.starts_with("record ") && l.contains(&other)) {
                    seen = true;
                }
                if l.starts_with("inbox:") {
                    break;
                }
            }
            if seen {
                leaks += 1.0;
            }
        }
        leak.samples.push(leaks);
        self.rows.extend([msg, leak]);
        Ok(())
    }

    /// The mini (reachable by UPnP, bound to every interface as a real install is) and this
    /// laptop (`--no-vpn`, so the path is the internet, not the tailnet).
    async fn direct(&mut self) -> Res<()> {
        // Fixed ports on the home Mac: each fresh dir would bind a new one, and the router's UPnP table
        // fills with the leases of earlier runs until it grants no more.
        let mut mini = self.remote("mini", "m", &["--name", "mini", "--no-nearby", "--port", "4111"])?;
        let mut lap = self.local("laptop", "l", &["--name", "laptop", "--no-nearby", "--no-vpn"])?;
        self.launch(&mut mini).await?;
        self.wait_global_addr(&mut mini).await;
        let link = self.invite(&mut mini, "invite").await?;
        self.launch(&mut lap).await?;
        self.add(&mut lap, &link).await?;
        lap.wait_ev("attach", Some(&mini.device.clone()), Duration::from_secs(20)).await.ok_or("laptop never attached the home Mac")?;
        let r = self.direct_runs(&mut lap, &mut mini).await;
        let _ = lap.stop().await;
        let _ = mini.stop().await;
        r
    }

    async fn direct_runs(&mut self, lap: &mut Node, mini: &mut Node) -> Res<()> {
        let runs = self.o.runs;
        let slow_runs = runs.div_ceil(2).max(1);
        let md = mini.device.clone();
        if self.wants("cold") {
            let mut open = Row::new(DATA, "open", "ms", 300.0, "300 ms");
            let mut online = Row::new(DATA, "open → online", "ms", 300.0, "300 ms");
            let mut dial = Row::new(DATA, "dial known device", "ms", 0.0, "");
            let mut launch = Row::new(DATA, "process launch → online", "ms", 500.0, "500 ms");
            for _ in 0..runs {
                lap.stop().await?;
                let started = self.launch(lap).await?;
                if let Some(v) = lap.last_open {
                    open.samples.push(v);
                }
                match lap.wait_ev("dial", Some(&md), Duration::from_secs(25)).await {
                    Some((_, v)) if v["ok"] == true => {
                        dial.took(v["ms"].as_f64(), &path_of(&v));
                        if let Some(r) = v["rtt"].as_f64() {
                            self.rtts.push(r);
                        }
                    }
                    _ => dial.failures += 1,
                }
                match lap.wait_ev("online", None, Duration::from_secs(25)).await {
                    Some((at, v)) => {
                        online.took(v["ms"].as_f64(), &path_of(&v));
                        launch.took(Some(ms_since(started, at)), "");
                    }
                    None => {
                        online.failures += 1;
                        launch.failures += 1;
                    }
                }
            }
            let rtt = median(&self.rtts).unwrap_or(0.0);
            dial.target = Some(rtt + 100.0);
            dial.target_text = format!("RTT+100 = {:.0} ms", rtt + 100.0);
            for r in [&mut open, &mut online, &mut dial, &mut launch] {
                r.timeout = 25_000.0;
            }
            self.rows.extend([open, online, dial, launch]);
        }
        if self.wants("online") {
            let mut a = Row::new(LOOP, "friend online seen, direct: laptop comes online → mini †", "ms", 2000.0, "2 s");
            let mut b = Row::new(LOOP, "friend online seen, direct: mini comes online → laptop †", "ms", 2000.0, "2 s");
            for _ in 0..slow_runs {
                lap.stop().await?;
                tokio::time::sleep(Duration::from_secs(3)).await;
                mini.drain();
                let t0 = self.launch(lap).await?;
                let ld = lap.device.clone();
                let got = mini.wait_ev("attach", Some(&ld), SLOW).await;
                a.took(got.as_ref().map(|(at, _)| ms_since(t0, *at)), &got.map(|(_, v)| path_of(&v)).unwrap_or_default());
                self.rejoin(lap, mini).await?;
                mini.stop().await?;
                tokio::time::sleep(Duration::from_secs(3)).await;
                lap.drain();
                let t0 = self.launch(mini).await?;
                let got = lap.wait_ev("attach", Some(&md), SLOW).await;
                b.took(got.as_ref().map(|(at, _)| ms_since(t0, *at)), &got.map(|(_, v)| path_of(&v)).unwrap_or_default());
                self.rejoin(lap, mini).await?;
            }
            for r in [&mut a, &mut b] {
                r.timeout = SLOW.as_millis() as f64;
            }
            self.rows.extend([a, b]);
        }
        if self.wants("record") {
            let mut a = Row::new(LOOP, "record change reaches mutual: laptop → mini †", "ms", 1000.0, "1 s");
            let mut b = Row::new(LOOP, "record change reaches mutual: mini → laptop †", "ms", 1000.0, "1 s");
            let ld = lap.device.clone();
            for i in 0..runs {
                mini.drain();
                let t0 = Instant::now();
                lap.send(&format!("tags a{i}")).await?;
                let got = mini.wait_ev("record", Some(&ld), Duration::from_secs(10)).await;
                a.took(got.map(|(at, _)| ms_since(t0, at)), "direct");
                lap.drain();
                let t0 = Instant::now();
                mini.send(&format!("tags b{i}")).await?;
                let got = lap.wait_ev("record", Some(&md), Duration::from_secs(10)).await;
                b.took(got.map(|(at, _)| ms_since(t0, at)), "direct");
            }
            for r in [&mut a, &mut b] {
                r.timeout = 10_000.0;
            }
            self.rows.extend([a, b]);
        }
        if self.wants("relaunch") {
            let mut a = Row::new(LOOP, "reconnect after relaunch (kill -9): laptop → mini sees it †", "ms", 2000.0, "2 s");
            let mut b = Row::new(LOOP, "reconnect after relaunch (kill -9): mini → laptop sees it †", "ms", 2000.0, "2 s");
            for _ in 0..slow_runs {
                lap.kill9().await?;
                mini.drain();
                let t0 = self.launch(lap).await?;
                let ld = lap.device.clone();
                let got = mini.wait_ev("attach", Some(&ld), SLOW).await;
                a.took(got.as_ref().map(|(at, _)| ms_since(t0, *at)), &got.map(|(_, v)| path_of(&v)).unwrap_or_default());
                self.rejoin(lap, mini).await?;
                mini.kill9().await?;
                lap.drain();
                let t0 = self.launch(mini).await?;
                let got = lap.wait_ev("attach", Some(&md), SLOW).await;
                b.took(got.as_ref().map(|(at, _)| ms_since(t0, *at)), &got.map(|(_, v)| path_of(&v)).unwrap_or_default());
                self.rejoin(lap, mini).await?;
            }
            for r in [&mut a, &mut b] {
                r.timeout = SLOW.as_millis() as f64;
            }
            self.rows.extend([a, b]);
        }
        if self.wants("wake") {
            let mut row = Row::new(LOOP, &format!("reconnect after wake ({} s stopped)", self.o.wake_secs), "ms", 2000.0, "2 s");
            for _ in 0..slow_runs {
                lap.send("offline").await?;
                tokio::time::sleep(Duration::from_millis(300)).await;
                lap.signal("STOP")?;
                tokio::time::sleep(Duration::from_secs(self.o.wake_secs)).await;
                lap.signal("CONT")?;
                lap.drain();
                lap.send("online").await?;
                let got = lap.wait_ev("wake", None, SLOW).await;
                row.took(got.as_ref().and_then(|(_, v)| v["ms"].as_f64()), &got.map(|(_, v)| path_of(&v)).unwrap_or_default());
                self.rejoin(lap, mini).await?;
            }
            row.timeout = SLOW.as_millis() as f64;
            self.rows.push(row);
        }
        if self.wants("reimport") {
            // An app that re-provides its library on every launch imports the same files again:
            // that must not hash them again, nor pile up open handles to them.
            let f = self.o.scratch.join("reimport.bin");
            std::fs::write(&f, vec![7u8; 64 * 1024 * 1024])?;
            let mut again = Row::new(DATA, "re-import of an unchanged 64 MB file (2nd and 3rd)", "ms", 50.0, "50 ms");
            let mut first = Row::new(DATA, "first import of it", "ms", 0.0, "");
            first.target = None;
            for i in 0..3 {
                lap.drain();
                let t = Instant::now();
                lap.send(&format!("blob-add {}", f.display())).await?;
                let got = lap.wait(|l| l.starts_with("blob ") || l.starts_with("error:"), Duration::from_secs(60)).await;
                let ms = got.filter(|(_, l)| l.starts_with("blob ")).map(|(at, _)| ms_since(t, at));
                if i == 0 { first.took(ms, "") } else { again.took(ms, "") }
            }
            let open_handles = |pid: Option<u32>| -> Option<f64> {
                let out = std::process::Command::new("lsof").args(["-p", &pid?.to_string()]).output().ok()?;
                Some(String::from_utf8_lossy(&out.stdout).lines().filter(|l| l.ends_with("reimport.bin")).count() as f64)
            };
            let mut handles = Row::new(DATA, "open handles to that file after three imports", "handles", 1.0, "≤ 1");
            handles.samples.extend(open_handles(lap.pid));
            // The store's own behaviour: the same bytes imported again for real (only the mtime moved).
            let mut rehashed = Row::new(DATA, "open handles after three real re-imports (touched, same bytes)", "handles", 1.0, "≤ 1");
            for i in 1..=3u64 {
                std::fs::File::options().write(true).open(&f)?.set_modified(std::time::SystemTime::now() + Duration::from_secs(i))?;
                lap.drain();
                lap.send(&format!("blob-add {}", f.display())).await?;
                lap.wait(|l| l.starts_with("blob ") || l.starts_with("error:"), Duration::from_secs(60)).await;
            }
            rehashed.samples.extend(open_handles(lap.pid));
            let _ = std::fs::remove_file(&f);
            // A library provided at once: 1,000 files of 256 KB, each read in place and so held
            // open while it hashes. The node counts its own open files every millisecond.
            let lib = self.o.scratch.join("library");
            std::fs::create_dir_all(&lib)?;
            for i in 0..1000u32 {
                let mut b = vec![0u8; 256 * 1024];
                b[..4].copy_from_slice(&i.to_le_bytes());
                std::fs::write(lib.join(format!("{i:04}.bin")), b)?;
            }
            lap.drain();
            let t = Instant::now();
            lap.send(&format!("blob-add-dir {}", lib.display())).await?;
            let got = lap.wait(|l| l.starts_with("blobs "), Duration::from_secs(300)).await;
            let mut fds = Row::new(DATA, "provide 1,000 paths at once: more files open, at most", "files", 15.0, "under 16");
            if let Some((at, l)) = got {
                let extra = l.split(", ").find_map(|p| p.strip_suffix(" more files open at most")).and_then(|n| n.parse::<f64>().ok());
                fds.samples.extend(extra);
                fds.note = format!("({}, {:.1} s)", l.trim_start_matches("blobs ").split(", ").take(2).collect::<Vec<_>>().join(", "), ms_since(t, at) / 1000.0);
            }
            let _ = std::fs::remove_dir_all(&lib);
            self.rows.extend([first, again, handles, rehashed, fds]);
        }
        if self.wants("phantom") {
            // A gateway's yes is not a mapping: whatever public address a relay node's invite
            // carries must be one the gateway holds. Against a router that answers success and
            // stores nothing, that means none at all, and no relay.
            let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/upnp-prune.py");
            let probe = std::process::Command::new("python3").args(["-I", script, "--probe"]).output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned()).unwrap_or_default();
            let mut row = Row::new(DATA, "router that answers success but stores nothing → reachable none, link carries no public address", "addresses", 0.0, "none it does not hold");
            let mut ph = self.local("phantom", "ph", &["--name", "ph", "--relay", "--no-nearby", "--port", "4191"])?;
            self.launch(&mut ph).await?;
            tokio::time::sleep(Duration::from_secs(8)).await;
            ph.drain();
            ph.send("status").await?;
            let relay = ph.wait(|l| l.starts_with("relay: "), Duration::from_secs(5)).await.map(|(_, l)| l).unwrap_or_default();
            let link = self.invite(&mut ph, "invite").await?;
            let held: Vec<u16> = std::process::Command::new("python3")
                .args(["-I", script, "--list"])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).lines().filter_map(|l| l.split(' ').next()?.parse().ok()).collect())
                .unwrap_or_default();
            let public: Vec<String> = peer::link::parse(&link)
                .map(|l| l.meet.addrs)
                .unwrap_or_default()
                .into_iter()
                .filter_map(|a| {
                    let hostport = a.strip_prefix("relay=").map(|u| u.split("//").nth(1).unwrap_or_default().split('/').next().unwrap_or_default().to_owned()).unwrap_or(a.clone());
                    let sa: std::net::SocketAddr = hostport.parse().ok()?;
                    peer::record::is_global(&sa.ip()).then_some(hostport)
                })
                .collect();
            let unheld = public.iter().filter(|hp| hp.rsplit(':').next().and_then(|p| p.parse::<u16>().ok()).is_none_or(|p| !held.contains(&p))).count();
            row.samples.push(unheld as f64);
            row.note = format!("(the gateway {probe}; {relay}; public addresses in the link: {})", if public.is_empty() { "none".into() } else { public.join(" ") });
            let _ = ph.stop().await;
            self.rows.push(row);
        }
        if self.wants("ipchange") {
            // Its own laptop node, bound to every interface as an app is: `--no-vpn` binds the
            // Wi-Fi address alone, and a socket on an address that vanished is not what an app has.
            let mut lapi = self.local("laptop-i", "li", &["--name", "lapi", "--no-nearby"])?;
            self.launch(&mut lapi).await?;
            let link = self.invite(mini, "invite").await?;
            self.add(&mut lapi, &link).await?;
            lapi.wait_ev("attach", Some(&md), Duration::from_secs(20)).await.ok_or("laptop-i never reached the home Mac")?;
            let r = self.ipchange(&mut lapi, &md).await;
            let _ = lapi.stop().await;
            r?;
            self.rejoin(lap, mini).await?;
        }
        if self.wants("dead") {
            let mut a = Row::new(LOOP, "dead peer offline: mini killed → laptop", "ms", 30_000.0, "30 s");
            let mut b = Row::new(LOOP, "dead peer offline: laptop killed → mini †", "ms", 30_000.0, "30 s");
            for _ in 0..slow_runs.min(2) {
                lap.drain();
                let t0 = Instant::now();
                mini.kill9().await?;
                let got = lap.wait_ev("detach", Some(&md), Duration::from_secs(70)).await;
                a.took(got.map(|(at, _)| ms_since(t0, at)), "");
                self.launch(mini).await?;
                self.rejoin(lap, mini).await?;
                mini.drain();
                let ld = lap.device.clone();
                let t0 = Instant::now();
                lap.kill9().await?;
                let got = mini.wait_ev("detach", Some(&ld), Duration::from_secs(70)).await;
                b.took(got.map(|(at, _)| ms_since(t0, at)), "");
                self.launch(lap).await?;
                self.rejoin(lap, mini).await?;
            }
            for r in [&mut a, &mut b] {
                r.timeout = 70_000.0;
            }
            self.rows.extend([a, b]);
        }
        if self.wants("message") {
            let mut row = Row::new(DATA, "message round trip (post → delivered)", "ms", 0.0, "");
            lap.drain();
            for i in 0..runs * 4 {
                lap.send(&format!("post mini bench {i}")).await?;
                let got = lap.wait_ev("post", None, Duration::from_secs(10)).await;
                row.took(got.as_ref().and_then(|(_, v)| v["ms"].as_f64()), got.as_ref().and_then(|(_, v)| v["via"].as_str()).unwrap_or(""));
            }
            let rtt = self.online_rtt(lap, &md).await.filter(|r| *r > 0.0).or_else(|| median(&self.rtts)).unwrap_or(0.0);
            row.target = Some(rtt + 50.0);
            row.target_text = format!("RTT+50 = {:.0} ms", rtt + 50.0);
            row.timeout = 10_000.0;
            self.rows.push(row);
        }
        if self.wants("blob") {
            let mut row = Row::new(DATA, &format!("{} MB blob, mini → laptop", self.o.blob_mb), "MB/s", 0.0, "");
            row.higher = true;
            let mut first = Row::new(DATA, "blob first byte", "ms", 1000.0, "1 s");
            let mut reference = Vec::new();
            for i in 0..2 {
                let f = format!("{}/peer-bench/big-{i}.bin", self.ssh.home);
                self.ssh.run(&format!("head -c {} /dev/urandom > {f}", self.o.blob_mb * 1024 * 1024)).await?;
                if i == 0 {
                    // The link, as ssh over the tailnet sees it: a reference, not a target.
                    let t = Instant::now();
                    let out = self.ssh.cmd().arg(format!("cat {f}")).stdout(Stdio::piped()).output().await?;
                    reference.push(out.stdout.len() as f64 / 1e6 / t.elapsed().as_secs_f64());
                }
                mini.send(&format!("blob-add {f}")).await?;
                let (_, l) = mini.wait(|l| l.starts_with("blob ") || l.starts_with("error:"), Duration::from_secs(60)).await.ok_or("blob-add timed out")?;
                let hash = l.trim_start_matches("blob ").to_owned();
                let to = self.o.scratch.join(format!("copy-{i}.bin"));
                lap.drain();
                lap.send(&format!("fetch mini {hash} {}", to.display())).await?;
                let got = lap.wait_ev("blob", None, Duration::from_secs(600)).await;
                row.took(got.as_ref().and_then(|(_, v)| v["mbps"].as_f64()).map(|m| m / 8.0), "direct");
                first.took(got.as_ref().and_then(|(_, v)| v["first_byte_ms"].as_f64()), "direct");
                let _ = std::fs::remove_file(&to);
                self.ssh.run(&format!("rm -f {f}")).await?;
            }
            if let Some(r) = median(&reference) {
                row.target = Some(r * 0.8);
                row.target_text = format!("80% of ssh's {r:.1} MB/s");
            }
            row.timeout = 0.0;
            first.timeout = 600_000.0;
            self.rows.extend([row, first]);
        }
        Ok(())
    }

    async fn ipchange(&mut self, lap: &mut Node, md: &str) -> Res<()> {
        let mut row = Row::new(LOOP, "reconnect after the network returns (Wi-Fi off 3 s, on), from its address's return", "ms", 2000.0, "migrated, or 2 s");
        row.timeout = 60_000.0;
        let ports = std::process::Command::new("networksetup").arg("-listallhardwareports").output()?;
        let text = String::from_utf8_lossy(&ports.stdout);
        let wifi = text.split("Hardware Port: Wi-Fi").nth(1).and_then(|r| r.lines().find_map(|l| l.strip_prefix("Device: "))).map(str::to_owned);
        let Some(wifi) = wifi else {
            row.note = "manual: no Wi-Fi device".into();
            self.rows.push(row);
            return Ok(());
        };
        // Once: it cuts this machine's network for everyone on it.
        for _ in 0..1 {
            lap.drain();
            let off = std::process::Command::new("networksetup").args(["-setairportpower", &wifi, "off"]).output()?;
            if !off.status.success() || !String::from_utf8_lossy(&off.stderr).trim().is_empty() {
                row.note = format!("manual: networksetup refused ({})", String::from_utf8_lossy(&off.stderr).trim());
                break;
            }
            let off_at = Instant::now();
            tokio::time::sleep(Duration::from_secs(3)).await;
            std::process::Command::new("networksetup").args(["-setairportpower", &wifi, "on"]).output()?;
            // The clock starts when the OS gives the machine an address again (its `net` event
            // that adds one); the outage and macOS rejoining Wi-Fi are not the node's to shorten.
            let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
            let (mut prev, mut back): (Option<Vec<Value>>, Option<f64>) = (None, None);
            let mut done = None;
            while done.is_none() {
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                let md = md.to_owned();
                let Some((at, l)) = lap.wait(move |l| is_ev(l, "net").is_some_and(|v| v["source"] == "os") || ((is_ev(l, "migrated").is_some() || is_ev(l, "redialed").is_some()) && trace_of(l).is_some_and(|v| v["device"] == md.as_str())), left).await else { break };
                let v = trace_of(&l).unwrap_or_default();
                if v["ev"] == "net" {
                    let now = v["addrs"].as_array().cloned().unwrap_or_default();
                    if prev.as_ref().is_some_and(|p| now.iter().any(|a| !p.contains(a))) {
                        back = v["t"].as_f64();
                    }
                    prev = Some(now);
                } else {
                    done = Some((at, v));
                }
            }
            let ms = done.as_ref().map(|(_, v)| match (back, v["t"].as_f64()) {
                (Some(b), Some(t)) => (t - b).max(0.0),
                _ => v["ms"].as_f64().unwrap_or(0.0),
            });
            row.took(ms, done.as_ref().and_then(|(_, v)| v["ev"].as_str()).unwrap_or(""));
            if let Some((at, _)) = &done {
                row.note = format!("({:.1} s after Wi-Fi off{})", ms_since(off_at, *at) / 1000.0, if back.is_none() { "; no address-return event, timed from the crate's last network change" } else { "" });
            }
            // Let the network settle (and ssh reconnect) before the next one.
            tokio::time::sleep(Duration::from_secs(10)).await;
        }
        self.rows.push(row);
        Ok(())
    }

    /// A relay on the home Mac (`--relay`, TCP port mapped), an unmapped box beside it and this laptop
    /// unmapped: the pair can only meet through the relay.
    async fn relayed(&mut self) -> Res<()> {
        let port = self.o.relay_port.to_string();
        let mut args = vec!["--name", "relay", "--port", &port, "--relay", "--auto-confirm-links", "--no-nearby"];
        if self.o.public_relays {
            args.push("--public");
        }
        let mut relay = self.remote("relay", "r", &args)?;
        let mut boxn = self.remote("box", "m2", &["--name", "box", "--no-nearby", "--no-portmap", "--no-vpn", "--port", "4132"])?;
        let mut lr = self.local("laptop-r", "lr", &["--name", "lapr", "--no-nearby", "--no-portmap", "--no-vpn"])?;
        self.launch(&mut relay).await?;
        let r = self.relayed_runs(&mut relay, &mut boxn, &mut lr).await;
        let _ = lr.stop().await;
        let _ = boxn.stop().await;
        let _ = relay.stop().await;
        r
    }

    async fn relayed_runs(&mut self, relay: &mut Node, boxn: &mut Node, lr: &mut Node) -> Res<()> {
        relay.send("status").await?;
        let (_, l) = relay.wait(|l| l.starts_with("relay: "), Duration::from_secs(10)).await.ok_or("relay status")?;
        if l.contains("none") {
            return Err("the remote relay was not offered (no TCP mapping)".into());
        }
        self.wait_global_addr(relay).await;
        let (l1, l2) = (self.invite(relay, "invite").await?, self.invite(relay, "invite").await?);
        self.launch(boxn).await?;
        self.add(boxn, &l2).await?;
        self.launch(lr).await?;
        self.add(lr, &l1).await?;
        lr.wait_ev("attach", Some(&relay.device.clone()), Duration::from_secs(20)).await.ok_or("laptop-r never reached the relay")?;
        // An invite names the relay only once this node is homed on it.
        for _ in 0..40 {
            lr.send("status").await?;
            if lr.wait(|l| l.starts_with("addresses:"), Duration::from_secs(5)).await.is_some_and(|(_, l)| l.contains("relay=")) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        let link = self.invite(lr, "invite").await?;
        self.add(boxn, &link).await?;
        let bd = boxn.device.clone();
        lr.wait_ev("attach", Some(&bd), Duration::from_secs(30)).await.ok_or("laptop-r never reached the box")?;
        let mut dial = Row::new(DATA, "relayed dial", "ms", 300.0, "300 ms");
        dial.timeout = 30_000.0;
        for _ in 0..self.o.runs {
            lr.stop().await?;
            self.launch(lr).await?;
            match lr.wait_ev("dial", Some(&bd), Duration::from_secs(30)).await {
                Some((_, v)) if v["ok"] == true => dial.took(v["ms"].as_f64(), &path_of(&v)),
                _ => dial.failures += 1,
            }
        }
        let mut a = Row::new(LOOP, "friend online seen, relayed: laptop comes online → box †", "ms", 5000.0, "5 s");
        let mut b = Row::new(LOOP, "friend online seen, relayed: box comes online → laptop †", "ms", 5000.0, "5 s");
        let mut rec = Row::new(LOOP, "record change reaches mutual: box → laptop, relayed †", "ms", 1000.0, "1 s");
        for _ in 0..self.o.runs.div_ceil(2).max(1) {
            if self.online_rtt(lr, &bd).await.is_none() {
                self.rejoin(lr, boxn).await?;
            }
            lr.stop().await?;
            tokio::time::sleep(Duration::from_secs(3)).await;
            boxn.drain();
            let t0 = self.launch(lr).await?;
            let ld = lr.device.clone();
            let got = boxn.wait_ev("attach", Some(&ld), SLOW).await;
            a.took(got.as_ref().map(|(at, _)| ms_since(t0, *at)), &got.map(|(_, v)| path_of(&v)).unwrap_or_default());
            self.rejoin(lr, boxn).await?;
            boxn.stop().await?;
            tokio::time::sleep(Duration::from_secs(3)).await;
            lr.drain();
            let t0 = self.launch(boxn).await?;
            let got = lr.wait_ev("attach", Some(&bd), SLOW).await;
            b.took(got.as_ref().map(|(at, _)| ms_since(t0, *at)), &got.map(|(_, v)| path_of(&v)).unwrap_or_default());
            self.rejoin(lr, boxn).await?;
            lr.drain();
            let t0 = Instant::now();
            boxn.send("tags moved").await?;
            let got = lr.wait_ev("record", Some(&bd), Duration::from_secs(10)).await;
            rec.took(got.map(|(at, _)| ms_since(t0, at)), "relayed");
        }
        for r in [&mut a, &mut b] {
            r.timeout = SLOW.as_millis() as f64;
        }
        rec.timeout = 10_000.0;
        self.rows.extend([a, b, rec, dial]);
        Ok(())
    }

    /// Own devices: `home` on the home Mac is the person's first device; this laptop links to it
    /// (a symmetric-NAT laptop redeems, the reachable device issues). A friend on the home Mac is
    /// added on the laptop; the home device must learn the contact and dial it.
    async fn own(&mut self) -> Res<()> {
        let mut home = self.remote("home", "home", &["--name", "dexter", "--auto-confirm-links", "--no-nearby", "--port", "4121"])?;
        // The tailnet is allowed here: these rows measure the book and the dial, not the NAT, and
        // they should not depend on the router granting yet another mapping.
        let mut lapo = self.local("laptop-o", "lo", &["--name", "x", "--no-nearby"])?;
        self.launch(&mut home).await?;
        let r = self.own_runs(&mut home, &mut lapo).await;
        let _ = lapo.stop().await;
        let _ = home.stop().await;
        r
    }

    async fn own_runs(&mut self, home: &mut Node, lapo: &mut Node) -> Res<()> {
        let link = self.invite(home, "link-device").await?;
        self.launch(lapo).await?;
        lapo.send(&format!("link {link}")).await?;
        lapo.wait(|l| l.starts_with("linked:") || l.starts_with("error:"), Duration::from_secs(40)).await.filter(|(_, l)| l.starts_with("linked:")).ok_or("laptop-o could not link to home")?;
        let hd = home.device.clone();
        if lapo.wait_ev("attach", Some(&hd), Duration::from_secs(20)).await.is_none() {
            self.rejoin(lapo, home).await?;
        }
        let mut contact = Row::new(LOOP, "contact added on laptop is on own device (home) †", "ms", 1000.0, "1 s");
        let mut dials = Row::new(LOOP, "own device dials the new contact †", "ms", 2000.0, "2 s");
        let names = ["f0", "f1", "f2", "f3", "f4"];
        for i in 0..self.o.runs.div_ceil(2).clamp(1, names.len()) {
            let port = (4122 + i).to_string();
            let mut f = self.remote(names[i], names[i], &["--name", &format!("ana{i}"), "--no-nearby", "--port", &port])?;
            self.launch(&mut f).await?;
            let link = self.invite(&mut f, "invite").await?;
            home.drain();
            let t0 = self.add(lapo, &link).await?;
            let fd = f.device.clone();
            let got = home.wait_ev("contact", None, Duration::from_secs(20)).await;
            contact.took(got.map(|(at, _)| ms_since(t0, at)), "");
            let got = home.wait_ev("attach", Some(&fd), Duration::from_secs(20)).await;
            dials.took(got.as_ref().map(|(at, _)| ms_since(t0, *at)), &got.map(|(_, v)| path_of(&v)).unwrap_or_default());
            let _ = f.stop().await;
        }
        contact.timeout = 20_000.0;
        dials.timeout = 20_000.0;
        self.rows.extend([contact, dials]);

        // Carried while away: the laptop's node quits; a friend posts to it; the home device (its
        // own device, connected to the friend) carries the envelope; the laptop's node starts
        // again and has it. Timed from its launch to its `inbox` line, on this machine.
        let mut carry = Row::new(LOOP, "carried while away: laptop returns → message in its inbox", "ms", 2000.0, "2 s");
        carry.timeout = 20_000.0;
        let mut f = self.remote("carrier-friend", "fc", &["--name", "ana", "--no-nearby", "--port", "4129"])?;
        self.launch(&mut f).await?;
        let link = self.invite(&mut f, "invite").await?;
        home.drain();
        self.add(lapo, &link).await?;
        let fd = f.device.clone();
        home.wait_ev("attach", Some(&fd), Duration::from_secs(20)).await.ok_or("home never reached the friend")?;
        let ld = lapo.device.clone();
        for i in 0..self.o.runs.div_ceil(2).max(1) {
            lapo.stop().await?;
            f.wait_ev("detach", Some(&ld), Duration::from_secs(10)).await;
            f.send(&format!("post dexter carried {i}")).await?;
            let ld2 = ld.clone();
            f.wait(move |l| l.starts_with("posted ") && l.contains(&ld2), Duration::from_secs(10)).await.ok_or("the friend could not post")?;
            let t0 = self.launch(lapo).await?;
            let got = lapo.wait_ev("inbox", None, Duration::from_secs(20)).await;
            carry.took(got.as_ref().map(|(at, _)| ms_since(t0, *at)), got.as_ref().and_then(|(_, v)| v["via"].as_str()).unwrap_or(""));
            if self.online_rtt(lapo, &home.device.clone()).await.is_none() {
                self.rejoin(lapo, home).await?;
            }
        }
        let _ = f.stop().await;
        self.rows.push(carry);
        Ok(())
    }
}
