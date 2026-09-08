//! Native clocks execute engine-issued registrations; scope meaning stays in Zig.
use crate::Runtime;
use gpui::{Context, Task};
use std::{collections::HashMap, time::Duration};

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Message {
    pub token: u64,
    pub period_ms: u64,
    pub action: u32,
    pub reserved: u32,
}

pub(crate) struct Manager {
    enabled: bool,
    jobs: HashMap<u64, Task<()>>,
}
impl Manager {
    pub(crate) fn new(enabled: bool) -> Self {
        Self {
            enabled,
            jobs: HashMap::new(),
        }
    }
    pub(crate) fn accept(&mut self, message: Message, cx: &mut Context<Runtime>) {
        assert_eq!(message.reserved, 0);
        assert_ne!(message.token, 0);
        assert!(matches!(message.action, 1 | 2));
        if !self.enabled {
            return;
        }
        match message.action {
            1 => {
                // Up to 256 old jobs may await their already-published cancellation
                // while 256 replacement jobs are read in the same UI turn.
                assert!(self.jobs.len() < 512);
                let token = message.token;
                let job = repeating(message.period_ms, cx, move |runtime, cx| {
                    runtime.timer_tick(token, cx)
                });
                assert!(
                    self.jobs.insert(token, job).is_none(),
                    "duplicate native timer"
                );
            }
            2 => {
                assert!(
                    self.jobs.remove(&message.token).is_some(),
                    "unknown native timer cancellation"
                );
            }
            _ => unreachable!(),
        }
    }
    pub(crate) fn shutdown(&mut self) {
        self.jobs.clear();
    }
}

fn repeating<T: 'static>(
    period_ms: u64,
    cx: &mut Context<T>,
    tick: impl Fn(&mut T, &mut Context<T>) -> bool + 'static,
) -> Task<()> {
    cx.spawn(async move |owner, cx| {
        loop {
            // Chunk very long periods so Instant arithmetic cannot overflow.
            // Zero periods yield via the executor's timer rather than a busy loop.
            let mut remaining = period_ms;
            loop {
                let chunk = remaining.min(86_400_000);
                if chunk == 0 {
                    yield_turn().await;
                } else {
                    cx.background_executor()
                        .timer(Duration::from_millis(chunk))
                        .await;
                }
                remaining -= chunk;
                if remaining == 0 {
                    break;
                }
            }
            if !owner
                .update(cx, |owner, cx| tick(owner, cx))
                .unwrap_or(false)
            {
                break;
            }
        }
    })
}

// GPUI completes a zero-duration timer synchronously. Yield the foreground
// future explicitly so an interval(0) cannot monopolize the current poll.
async fn yield_turn() {
    let mut yielded = false;
    std::future::poll_fn(|cx| {
        if yielded {
            std::task::Poll::Ready(())
        } else {
            yielded = true;
            cx.waker().wake_by_ref();
            std::task::Poll::Pending
        }
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{AppContext, TestAppContext};

    #[test]
    fn zero_period_wait_cannot_complete_in_the_current_poll() {
        use std::{
            future::Future,
            task::{Context, Poll, Waker},
        };
        let mut wait = std::pin::pin!(yield_turn());
        let mut cx = Context::from_waker(Waker::noop());
        assert_eq!(wait.as_mut().poll(&mut cx), Poll::Pending);
        assert_eq!(wait.as_mut().poll(&mut cx), Poll::Ready(()));
    }

    struct Clock {
        ticks: usize,
        job: Option<Task<()>>,
    }

    #[gpui::test]
    fn native_periods_tick_and_disposal_cancels_future_wakes(cx: &mut TestAppContext) {
        let clock = cx.new(|cx| Clock {
            ticks: 0,
            job: Some(repeating(500, cx, |clock: &mut Clock, _| {
                clock.ticks += 1;
                true
            })),
        });
        cx.run_until_parked();
        cx.background_executor
            .advance_clock(Duration::from_millis(499));
        cx.run_until_parked();
        clock.read_with(cx, |clock, _| assert_eq!(clock.ticks, 0));
        cx.background_executor
            .advance_clock(Duration::from_millis(1));
        cx.run_until_parked();
        clock.read_with(cx, |clock, _| assert_eq!(clock.ticks, 1));
        clock.update(cx, |clock, _| {
            clock.job.take();
        });
        cx.background_executor.advance_clock(Duration::from_secs(5));
        cx.run_until_parked();
        clock.read_with(cx, |clock, _| assert_eq!(clock.ticks, 1));
    }
}
