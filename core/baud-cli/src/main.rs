//! `baud`: one baud device in a terminal, for the interop lab. It opens a core in `--dir`, runs
//! the steps it is given in order (each `wait-…` blocks until it holds or its seconds run out,
//! which fails the run), and prints what arrives as it arrives:
//!
//!   baud --dir /tmp/ana --name Ana 'invite-file /tmp/link' 'wait-contact Mac 60' \
//!        'wait-chat Mac 30' 'send Mac hello' 'photo Mac /tmp/a.jpg' 'wait-delivered Mac 30 hello'
//!
//! It never asks the router for a port (`--portmap` turns that on), and confirms every device
//! link request (a lab has nobody to read the code).

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use baud_core::Core;
use baud_core::types::*;

/// Secrets as files in `<dir>/keys`, mode 0600: a lab's keychain.
struct FileKeys(PathBuf);
impl peer::identity::Keychain for FileKeys {
    fn get(&self, item: &str) -> peer::Result<Option<Vec<u8>>> {
        Ok(std::fs::read(self.0.join(item)).ok())
    }
    fn put(&self, item: &str, bytes: &[u8]) -> peer::Result<()> {
        std::fs::create_dir_all(&self.0).map_err(|e| peer::Error::Keychain(e.to_string()))?;
        let p = self.0.join(item);
        std::fs::write(&p, bytes).map_err(|e| peer::Error::Keychain(e.to_string()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600));
        }
        Ok(())
    }
    fn delete(&self, item: &str) -> peer::Result<()> {
        let _ = std::fs::remove_file(self.0.join(item));
        Ok(())
    }
}

fn say(line: impl AsRef<str>) {
    let t = chrono_ish();
    println!("{t} {}", line.as_ref());
}

fn chrono_ish() -> String {
    let ms = baud_core::sentences::now_ms();
    format!("{}.{:03}", (ms / 1000) % 100_000, ms % 1000)
}

struct Lab {
    core: Arc<Core>,
}

impl Lab {
    fn contact(&self, name: &str) -> Option<Contact> {
        self.core.contacts().into_iter().find(|c| c.name.eq_ignore_ascii_case(name) || c.name.to_lowercase().starts_with(&name.to_lowercase()))
    }
    fn chat(&self, name: &str) -> Option<Conversation> {
        let c = self.contact(name)?;
        self.core.conversations(Some(Kind::Chat)).into_iter().find(|x| x.is_direct && x.members.contains(&c.user))
    }
    fn name_of(&self, user: &str) -> String {
        if user == self.core.me().user {
            return "me".into();
        }
        self.core.contacts().into_iter().find(|c| c.user == user).map(|c| c.name).unwrap_or_else(|| user[..8.min(user.len())].to_owned())
    }

    async fn until<T>(&self, what: &str, secs: f64, mut f: impl FnMut() -> Option<T>) -> Result<T> {
        let t0 = Instant::now();
        loop {
            if let Some(v) = f() {
                return Ok(v);
            }
            if t0.elapsed().as_secs_f64() > secs {
                bail!("timed out after {secs} s waiting for {what}");
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    async fn file(&self, path: &str, secs: f64) -> Result<String> {
        self.until(&format!("{path}"), secs, || std::fs::read_to_string(path).ok().map(|s| s.trim().to_owned()).filter(|s| !s.is_empty())).await
    }

    fn message(&self, name: &str, text: &str) -> Option<Event> {
        let conv = self.chat(name)?;
        self.core.events(&conv.id, None, 200).into_iter().find(|e| e.kind == EventType::Message && e.text.as_deref().unwrap_or("").contains(text))
    }

    async fn step(&self, line: &str) -> Result<()> {
        let mut w = line.split_whitespace();
        let cmd = w.next().unwrap_or("");
        let args: Vec<&str> = w.collect();
        let arg = |i: usize| args.get(i).copied().ok_or_else(|| anyhow!("{cmd}: argument {} missing", i + 1));
        let secs = |i: usize| args.get(i).and_then(|s| s.parse::<f64>().ok()).unwrap_or(60.0);
        let rest = |i: usize| args.get(i..).map(|a| a.join(" ")).unwrap_or_default();
        say(format!("step {line}"));
        match cmd {
            "name" => self.core.set_name(&rest(0))?,
            "invite-file" => {
                let l = self.core.invite()?;
                std::fs::write(arg(0)?, &l.url)?;
                say(format!("invite {} ({} ch, expires {})", &l.code[..12.min(l.code.len())], l.url.len(), l.expires / 1000));
            }
            "add-file" => {
                let url = self.file(arg(0)?, secs(1)).await?;
                let c = self.core.add(&url).await?;
                say(format!("added {}: {}", c.name, c.sentence));
            }
            "reply-file" => {
                // reply-file IN OUT: answer the friend link in IN with a reply, written to OUT.
                let url = self.file(arg(0)?, secs(2)).await?;
                let r = self.core.reply(&url)?;
                std::fs::write(arg(1)?, &r.url)?;
                say(format!("answered the link, good for {} min", (r.expires - baud_core::sentences::now_ms()) / 60_000));
            }
            "link-file" => {
                let l = self.core.link_device()?;
                std::fs::write(arg(0)?, &l.url)?;
                say("device link written");
            }
            "join-file" => {
                let url = self.file(arg(0)?, secs(1)).await?;
                say(format!("joining, code {}", self.core.joining_code(&url).unwrap_or_default()));
                self.core.link(&url).await?;
                say(format!("joined {}: devices {}", self.core.me().name, self.core.me().devices.len()));
            }
            "wait-devices" => {
                let n: usize = arg(0)?.parse()?;
                self.until("my devices", secs(1), || (self.core.me().devices.len() >= n).then_some(())).await?;
            }
            "wait-contact" => {
                let c = self.until("a contact", secs(1), || self.contact(arg(0).ok()?)).await?;
                say(format!("contact {} {}", c.name, c.sentence));
            }
            "wait-online" => {
                self.until("online", secs(1), || self.contact(arg(0).ok()?).filter(|c| c.online)).await?;
            }
            "wait-offline" => {
                self.until("offline", secs(1), || self.contact(arg(0).ok()?).filter(|c| !c.online)).await?;
            }
            "wait-chat" => {
                let c = self.until("the chat", secs(1), || self.chat(arg(0).ok()?)).await?;
                say(format!("chat {} with {:?}", &c.id[..8], c.members.iter().map(|m| self.name_of(m)).collect::<Vec<_>>()));
            }
            "send" => {
                let conv = self.chat(arg(0)?).context("no chat")?;
                let e = self.core.send(&conv.id, Draft { text: rest(1), ..Default::default() })?;
                say(format!("sent {} '{}'", &e.id[..8], rest(1)));
            }
            "photo" => {
                let conv = self.chat(arg(0)?).context("no chat")?;
                let e = self.core.send(&conv.id, Draft { text: rest(2), attachments: vec![arg(1)?.to_owned()], ..Default::default() })?;
                let a = &e.attachments[0];
                say(format!("sent photo {} {} {} bytes {}x{} hash {}", &e.id[..8], a.mime, a.size, a.width.unwrap_or(0), a.height.unwrap_or(0), &a.hash[..12]));
            }
            "wait-text" => {
                let text = rest(2);
                let e = self.until(&format!("'{text}'"), secs(1), || self.message(arg(0).ok()?, &text)).await?;
                say(format!("got '{}' from {} via {:?} carried by {}", e.text.unwrap_or_default(), self.name_of(&e.user), e.via, e.carried_by.as_deref().map(|c| &c[..8]).unwrap_or("-")));
            }
            "wait-delivered" | "wait-read" | "wait-carried" => {
                let text = rest(2);
                let conv = self.chat(arg(0)?).context("no chat")?;
                let e = self.message(arg(0)?, &text).context("no such message")?;
                let d = self
                    .until(cmd, secs(1), || {
                        let d = self.core.delivery(&conv.id, &e.id);
                        let ok = match cmd {
                            "wait-read" => d.best == DeliveryState::Read,
                            "wait-carried" => matches!(d.best, DeliveryState::Carried { .. }) || d.devices.iter().any(|x| matches!(x.state, DeliveryState::Carried { .. })),
                            _ => matches!(d.best, DeliveryState::Delivered | DeliveryState::Read),
                        };
                        ok.then_some(d)
                    })
                    .await?;
                say(format!("delivery '{text}': {}", d.sentence));
            }
            "read" => {
                let conv = self.chat(arg(0)?).context("no chat")?;
                if let Some(last) = conv.last_event {
                    self.core.mark_read(&conv.id, &last)?;
                }
            }
            "fetch-all" => {
                let conv = self.chat(arg(0)?).context("no chat")?;
                let atts: Vec<Attachment> = self.core.events(&conv.id, None, 200).into_iter().filter(|e| !e.mine).flat_map(|e| e.attachments).collect();
                if atts.is_empty() {
                    bail!("no files in the chat");
                }
                for a in atts {
                    let t0 = Instant::now();
                    let p = tokio::time::timeout(Duration::from_secs_f64(secs(1)), self.core.blob(&a.hash, &a.key)).await.map_err(|_| anyhow!("{} never came", a.hash))??;
                    let ok = baud_core::file_hash(Path::new(&p))? == a.hash;
                    say(format!("file {} {} {} bytes {}x{} here in {} ms, hash {}", a.name.as_deref().unwrap_or("?"), a.mime, a.size, a.width.unwrap_or(0), a.height.unwrap_or(0), t0.elapsed().as_millis(), if ok { "ok" } else { "MISMATCH" }));
                    if !ok {
                        bail!("hash mismatch");
                    }
                }
            }
            "status" => {
                let me = self.core.me();
                say(format!("me {} {} devices {:?}", me.name, &me.user[..8], me.devices.iter().map(|d| format!("{} {}", d.name, d.sentence)).collect::<Vec<_>>()));
                for c in self.core.contacts() {
                    say(format!("contact {} · {} · {:?}", c.name, c.sentence, c.devices.iter().map(|d| format!("{} ({:?})", d.name, d.kind)).collect::<Vec<_>>()));
                }
                for c in self.core.conversations(None) {
                    say(format!("chat {} {:?} unread {} · {:?}", &c.id[..8], c.name, c.unread, c.last_text));
                }
                say(format!("carrying: {} · net: {:?}", self.core.carrying().sentence, self.core.net_state()));
            }
            "share" => {
                // share NAME [minutes]: my location in our chat, for that long or until I stop.
                let conv = self.chat(arg(0)?).context("no chat")?;
                let until = args.get(1).and_then(|m| m.parse::<i64>().ok()).map(|m| baud_core::sentences::now_ms() + m * 60_000);
                self.core.share_place(&conv.id, until);
                say(format!("sharing in {} {}", &conv.id[..8], if until.is_some() { "for a while" } else { "until I stop" }));
            }
            "stop-sharing" => {
                let conv = self.chat(arg(0)?).context("no chat")?;
                self.core.stop_sharing(&conv.id);
            }
            "move" => {
                let n = |i: usize| -> Result<f64> { Ok(arg(i)?.parse::<f64>()?) };
                self.core.moved(n(0)?, n(1)?, args.get(2).and_then(|a| a.parse().ok()).unwrap_or(10.0));
            }
            "wait-place" | "wait-no-place" => {
                let c = self.contact(arg(0)?).context("no such contact")?;
                let conv = self.chat(arg(0)?).context("no chat")?;
                let gone = cmd == "wait-no-place";
                let p = self.until(cmd, secs(1), || {
                    let p = self.core.places(&conv.id).into_iter().find(|p| p.user == c.user);
                    if gone { p.is_none().then_some(None) } else { p.map(Some) }
                }).await?;
                match p {
                    Some(p) => say(format!("{} is at {:.4},{:.4} ±{} m, {}", c.name, p.lat, p.lon, p.accuracy, if p.until.is_some() { "for a while" } else { "until they stop" })),
                    None => say(format!("{} stopped sharing", c.name)),
                }
            }
            "wake-health" => {
                let url = format!("{}/health", baud_core::WAKE_RELAY);
                let code = baud_core::relay_get(&url).await;
                say(format!("{url}: {code:?}"));
                if code != Some(200) {
                    bail!("the wake relay didn't answer");
                }
            }
            "sleep" | "stay" => tokio::time::sleep(Duration::from_secs_f64(secs(0))).await,
            "offline" => self.core.set_online(false),
            "online" => self.core.set_online(true),
            "quit" => {}
            other => bail!("no step {other}"),
        }
        Ok(())
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut flag = |name: &str| -> Option<String> {
        let i = args.iter().position(|a| a == name)?;
        let v = args.get(i + 1).cloned();
        args.drain(i..(i + 2).min(args.len()));
        v
    };
    let dir = PathBuf::from(flag("--dir").context("--dir")?);
    let name = flag("--name").unwrap_or_default();
    let device = flag("--device").unwrap_or_else(|| format!("{name}'s node"));
    let portmap = flag("--portmap").map(|v| v == "1").unwrap_or(false);
    let nearby = flag("--nearby").map(|v| v == "1").unwrap_or(false);
    let steps = args;

    std::fs::create_dir_all(&dir)?;
    let mut config = Config::new(&name, &device, DeviceKind::Android);
    config.portmap = portmap;
    config.nearby = nearby;
    let core = Core::open(dir.clone(), Arc::new(FileKeys(dir.join("keys"))), config).await?;
    let me = core.me();
    say(format!("open {} as {} ({}…) on {}… · {}", dir.display(), me.name, &me.user[..8], &me.this_device[..8], baud_core::version()));
    if !name.is_empty() && me.name != name {
        core.set_name(&name)?;
    }
    core.set_online(true);
    let lab = Arc::new(Lab { core: core.clone() });

    // What arrives, as it arrives: new messages by id, link requests confirmed.
    let seen = Arc::new(std::sync::Mutex::new(std::collections::HashSet::<String>::new()));
    for c in core.conversations(None) {
        for e in core.events(&c.id, None, 500) {
            seen.lock().unwrap().insert(e.id);
        }
    }
    let watcher = lab.clone();
    let _sub = core.subscribe(Box::new(move |change| match change {
        Change::Conversation { id } => {
            for e in watcher.core.events(&id, None, 20) {
                if e.kind == EventType::Message && !e.mine && seen.lock().unwrap().insert(e.id.clone()) {
                    say(format!(
                        "msg from {}: '{}' via {:?} carried by {} files {}",
                        watcher.name_of(&e.user),
                        e.text.unwrap_or_default(),
                        e.via,
                        e.carried_by.as_deref().map(|c| &c[..8]).unwrap_or("-"),
                        e.attachments.len()
                    ));
                }
            }
        }
        Change::LinkRequest { req, code, name, .. } => {
            say(format!("link request from {name}, code {code}: confirmed"));
            watcher.core.confirm_link(req, true);
        }
        Change::Removed => say("removed by another of my devices"),
        _ => {}
    }));

    let mut failed = None;
    for s in &steps {
        if let Err(e) = lab.step(s).await {
            say(format!("FAILED {s}: {e}"));
            failed = Some(e);
            break;
        }
    }
    core.close().await;
    say(if failed.is_some() { "done, failed" } else { "done, ok" });
    std::process::exit(if failed.is_some() { 1 } else { 0 });
}
