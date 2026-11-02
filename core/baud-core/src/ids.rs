//! The ids and numbers both platforms must compute alike (`Keys.swift`): event ids, conversation
//! ids, my chat with myself, the card's safety number.

/// A stable id from a string: 32 hex chars of a cheap hash (FNV-1a and a golden-ratio sum).
pub fn stable_id(s: &str) -> String {
    let (mut h1, mut h2): (u64, u64) = (0xcbf29ce484222325, 0x84222325cbf29ce4);
    for b in s.bytes() {
        h1 = (h1 ^ b as u64).wrapping_mul(0x100000001b3);
        h2 = h2.wrapping_add(b as u64).wrapping_mul(0x9E3779B97F4A7C15);
    }
    format!("{h1:016x}{h2:016x}")
}

/// An event's id: its feed and place in it.
pub fn event_id(conv: &str, device: &str, seq: u64) -> String {
    stable_id(&format!("{conv}/{device}/{seq}"))
}

/// My chat with myself: the same id on every device of mine, 32 bytes like a group's.
pub fn home_id(user: &str) -> String {
    stable_id(&format!("home:{user}")) + &stable_id(&format!("home2:{user}"))
}

/// A new conversation's id, 32 bytes as the crate's group ids are.
pub fn new_conversation_id(device: &str) -> String {
    let seed = format!("conv:{device}:{}", uuid());
    stable_id(&seed) + &stable_id(&format!("2:{seed}"))
}

/// 60 digits from a user key, in groups of five: what a WireCard carries as its fingerprint.
pub fn fingerprint(user: &str) -> String {
    let mut x = user.bytes().fold(0x9E3779B97F4A7C15u64, |x, b| (x ^ b as u64).wrapping_mul(0x100000001b3));
    let mut digits = String::new();
    while digits.len() < 60 {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        digits += &format!("{:05}", (x >> 33) % 100_000);
    }
    (0..12).map(|i| &digits[i * 5..i * 5 + 5]).collect::<Vec<_>>().join(" ")
}

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub fn random_hex(n: usize) -> String {
    hex(&(0..n).map(|_| rand::random::<u8>()).collect::<Vec<_>>())
}

/// An uppercase v4 UUID, as Foundation's `UUID().uuidString` reads.
pub fn uuid() -> String {
    let mut b: [u8; 16] = rand::random();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = hex(&b).to_uppercase();
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}
