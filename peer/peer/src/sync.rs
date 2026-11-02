//! Locks that outlive a panic. A task that panics while holding a std lock poisons it, and every
//! later `lock().unwrap()` panics in turn: one bug in a background task took down every call
//! after it, the app's own on its main thread (baud 0.2.7, a trap in `networkChanged`). A guard
//! is taken back from a poisoned lock instead. Whatever the panic left half-done, the node goes
//! on; nothing is worse than an app that traps on every call after it.

use std::sync::{Mutex, MutexGuard, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard};

pub trait Locked<T: ?Sized> {
    /// `lock()`, poisoned or not.
    fn locked(&self) -> MutexGuard<'_, T>;
}

impl<T: ?Sized> Locked<T> for Mutex<T> {
    fn locked(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

pub trait Shared<T: ?Sized> {
    /// `read()`, poisoned or not.
    fn reading(&self) -> RwLockReadGuard<'_, T>;
    /// `write()`, poisoned or not.
    fn writing(&self) -> RwLockWriteGuard<'_, T>;
}

impl<T: ?Sized> Shared<T> for RwLock<T> {
    fn reading(&self) -> RwLockReadGuard<'_, T> {
        self.read().unwrap_or_else(PoisonError::into_inner)
    }
    fn writing(&self) -> RwLockWriteGuard<'_, T> {
        self.write().unwrap_or_else(PoisonError::into_inner)
    }
}
