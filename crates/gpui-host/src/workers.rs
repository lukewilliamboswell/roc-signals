//! Worker threads for Roc effects, and the mailbox that carries their
//! completions and the choosers they wait on back to the UI thread.
//!
//! Every effect runs on its own thread: a pool hands a job to an idle worker
//! and spawns a new one when none is idle, so an effect blocked on a dialog or
//! on slow I/O never delays another. Workers that stay idle exit.
use crate::{Runtime, effects::ChooserRequest};
use gpui::Context;
use std::{
    collections::VecDeque,
    future::Future,
    pin::Pin,
    sync::{Condvar, Mutex},
    task::{Context as TaskContext, Poll, Waker},
    thread,
    time::Duration,
};

/// What a worker thread needs the UI thread to do.
pub(crate) enum Message {
    /// A prepared effect finished; the engine applies its result.
    Completed(u64),
    /// An effect is blocked waiting for a native chooser to be shown.
    Chooser(ChooserRequest),
}

struct Mailbox {
    messages: VecDeque<Message>,
    waker: Option<Waker>,
    listening: bool,
}

static MAILBOX: Mutex<Mailbox> = Mutex::new(Mailbox {
    messages: VecDeque::new(),
    waker: None,
    listening: false,
});

/// Posts a message for the UI thread. Returns false when no window is
/// listening, in which case the message is dropped.
pub(crate) fn post(message: Message) -> bool {
    let waker = {
        let mut mailbox = MAILBOX.lock().unwrap();
        if !mailbox.listening {
            return false;
        }
        mailbox.messages.push_back(message);
        mailbox.waker.take()
    };
    if let Some(waker) = waker {
        waker.wake();
    }
    true
}

/// Resolves with the next posted message; a worker's post wakes it on the UI
/// thread's executor.
struct NextMessage;

impl Future for NextMessage {
    type Output = Message;
    fn poll(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<Message> {
        let mut mailbox = MAILBOX.lock().unwrap();
        if let Some(message) = mailbox.messages.pop_front() {
            return Poll::Ready(message);
        }
        mailbox.waker = Some(cx.waker().clone());
        Poll::Pending
    }
}

/// Starts the UI-thread listener that serves worker messages. One runtime
/// listens at a time; a dropped runtime frees the slot for the next.
pub(crate) fn listen(cx: &mut Context<Runtime>) {
    {
        let mut mailbox = MAILBOX.lock().unwrap();
        if mailbox.listening {
            return;
        }
        mailbox.listening = true;
    }
    cx.spawn(async move |runtime, cx| {
        loop {
            let message = NextMessage.await;
            let delivered = runtime.update(cx, |runtime, cx| match message {
                Message::Completed(job) => runtime.complete_roc_effect(job, cx),
                Message::Chooser(request) => crate::effects::prompt(request, cx),
            });
            if delivered.is_err() {
                break;
            }
        }
        MAILBOX.lock().unwrap().listening = false;
    })
    .detach();
}

type Job = (unsafe extern "C" fn(u64), u64);

struct Pool {
    jobs: VecDeque<Job>,
    idle: usize,
}

static POOL: Mutex<Pool> = Mutex::new(Pool {
    jobs: VecDeque::new(),
    idle: 0,
});
static WAKE: Condvar = Condvar::new();
const IDLE_TIMEOUT: Duration = Duration::from_secs(30);
/// Roc effect code recurses freely, so workers get the main thread's stack size.
const STACK_BYTES: usize = 8 << 20;

/// Runs one prepared effect on a worker thread, spawning a thread when every
/// worker is busy or blocked.
pub(crate) fn run(run: unsafe extern "C" fn(u64), job: u64) {
    let mut pool = POOL.lock().unwrap();
    pool.jobs.push_back((run, job));
    if pool.idle == 0 {
        thread::Builder::new()
            .name("roc-effect".into())
            .stack_size(STACK_BYTES)
            .spawn(worker)
            .expect("effect worker thread failed to start");
    } else {
        WAKE.notify_one();
    }
}

fn worker() {
    loop {
        let (run, job) = {
            let mut pool = POOL.lock().unwrap();
            loop {
                if let Some(job) = pool.jobs.pop_front() {
                    break job;
                }
                pool.idle += 1;
                let (guard, timeout) = WAKE.wait_timeout(pool, IDLE_TIMEOUT).unwrap();
                pool = guard;
                pool.idle -= 1;
                if timeout.timed_out() && pool.jobs.is_empty() {
                    return;
                }
            }
        };
        unsafe { run(job) };
        post(Message::Completed(job));
    }
}
