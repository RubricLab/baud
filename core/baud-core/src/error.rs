//! Flat errors, each displayed as the sentence the UI shows (`CoreError` and `Crate.sentence`).

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    #[error("That doesn't exist here.")]
    NotFound,
    #[error("That link has expired. Ask for a new one.")]
    Expired,
    #[error("That link was already used. Ask for a new one.")]
    Used,
    #[error("That isn't a baud link.")]
    BadLink,
    #[error("Only an admin can do that.")]
    NotAdmin,
    #[error("You're not in that conversation.")]
    NotMember,
    /// Their gate closed: the other side said no.
    #[error("{0}")]
    Refused(String),
    #[error("{0}")]
    Offline(String),
    #[error("{0}")]
    Unreachable(String),
    #[error("{0}")]
    Store(String),
    #[error("{0}")]
    Failed(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error::Store(e.to_string())
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Failed(e.to_string())
    }
}

impl Error {
    /// The crate's error, with the other side named: `own` when it is my own device (a link).
    pub fn from_peer(e: peer::Error, name: &str, own: bool) -> Error {
        use peer::Error as E;
        let theirs = if own { "your other device".to_owned() } else { format!("{name}'s device") };
        let fresh = if own { "Make a new one on your other device.".to_owned() } else { format!("Ask {name} for a fresh one.") };
        match e {
            E::Expired => Error::Expired,
            E::Used => Error::Used,
            E::NotInTheirBook => Error::Refused(if own { "Your other device said no.".into() } else { format!("{name}'s device said no.") }),
            E::Unreachable | E::Net(_) => Error::Unreachable(format!(
                "Couldn't reach {theirs}. baud has to be open there, and online or through one of your devices. Try again, or ask for a fresh link."
            )),
            E::Encoding | E::BadKey | E::BadSignature => Error::BadLink,
            E::NotFound => Error::NotFound,
            other => Error::Failed(format!("{other}. {fresh}")),
        }
    }
}
