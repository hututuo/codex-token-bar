use std::io::Read;
use std::sync::{mpsc, Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

const READ_BUFFER_BYTES: usize = 8 * 1024;
const CANCEL_JOIN_GRACE: Duration = Duration::from_millis(250);

/// Collects the bounded tail of a child-process pipe without ever requiring the
/// caller to wait forever for a descendant that inherited the write end.
pub(crate) struct ProcessPipeTail {
    reader: Option<JoinHandle<()>>,
    completion: Option<mpsc::Receiver<()>>,
    #[cfg(unix)]
    cancel: Option<std::os::fd::OwnedFd>,
    tail: Arc<Mutex<Vec<u8>>>,
    natural_drain_grace: Duration,
}

impl ProcessPipeTail {
    #[cfg(unix)]
    pub(crate) fn spawn<R>(
        pipe: Option<R>,
        limit: usize,
        natural_drain_grace: Duration,
    ) -> Self
    where
        R: Into<std::os::fd::OwnedFd>,
    {
        let Some(pipe) = pipe else {
            return Self::empty(limit, natural_drain_grace);
        };
        let pipe_fd: std::os::fd::OwnedFd = pipe.into();
        let (cancel_read, cancel_write) = match rustix::pipe::pipe() {
            Ok(pipe) => pipe,
            Err(_) => {
                // If the self-pipe cannot be allocated, retain bounded caller
                // latency by falling back to a detachable blocking reader.
                // The owned descriptor remains managed; do not leak it.
                return Self::spawn_blocking(
                    Some(std::fs::File::from(pipe_fd)),
                    limit,
                    natural_drain_grace,
                );
            }
        };
        let tail = Arc::new(Mutex::new(Vec::with_capacity(limit)));
        let reader_tail = tail.clone();
        let (sender, receiver) = mpsc::sync_channel(1);
        let reader = std::thread::spawn(move || {
            use rustix::event::{PollFd, PollFlags};

            let mut buffer = [0_u8; READ_BUFFER_BYTES];
            loop {
                let mut fds = [
                    PollFd::new(&pipe_fd, PollFlags::IN),
                    PollFd::new(&cancel_read, PollFlags::IN),
                ];
                match rustix::event::poll(&mut fds, None) {
                    Ok(_) => {}
                    Err(rustix::io::Errno::INTR) => continue,
                    Err(_) => break,
                }
                let pipe_ready = !fds[0].revents().is_empty();
                let cancel_ready = !fds[1].revents().is_empty();
                if cancel_ready {
                    // Cancellation wins over data readiness. Otherwise a
                    // continuously-ready writer can starve the cancel branch.
                    let nonblocking = rustix::fs::fcntl_getfl(&pipe_fd)
                        .and_then(|flags| {
                            rustix::fs::fcntl_setfl(
                                &pipe_fd,
                                flags | rustix::fs::OFlags::NONBLOCK,
                            )
                        })
                        .is_ok();
                    if nonblocking {
                        let drain_reads = limit.div_ceil(READ_BUFFER_BYTES).max(1);
                        for _ in 0..drain_reads {
                            match rustix::io::read(&pipe_fd, &mut buffer) {
                                Ok(0) => break,
                                Ok(count) => {
                                    let mut current = reader_tail
                                        .lock()
                                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                                    append_tail(&mut current, &buffer[..count], limit);
                                }
                                Err(rustix::io::Errno::INTR) => continue,
                                Err(_) => break,
                            }
                        }
                    }
                    break;
                }
                if pipe_ready {
                    match rustix::io::read(&pipe_fd, &mut buffer) {
                        Ok(0) => break,
                        Ok(count) => {
                            let mut current = reader_tail
                                .lock()
                                .unwrap_or_else(|poisoned| poisoned.into_inner());
                            append_tail(&mut current, &buffer[..count], limit);
                        }
                        Err(rustix::io::Errno::INTR) => continue,
                        Err(_) => break,
                    }
                }
            }
            let _ = sender.send(());
        });
        Self {
            reader: Some(reader),
            completion: Some(receiver),
            cancel: Some(cancel_write),
            tail,
            natural_drain_grace,
        }
    }

    #[cfg(windows)]
    pub(crate) fn spawn<R>(
        pipe: Option<R>,
        limit: usize,
        natural_drain_grace: Duration,
    ) -> Self
    where
        R: Read + Send + 'static,
    {
        Self::spawn_blocking(pipe, limit, natural_drain_grace)
    }

    #[cfg(all(not(unix), not(windows)))]
    pub(crate) fn spawn<R>(
        pipe: Option<R>,
        limit: usize,
        natural_drain_grace: Duration,
    ) -> Self
    where
        R: Read + Send + 'static,
    {
        Self::spawn_blocking(pipe, limit, natural_drain_grace)
    }

    fn empty(limit: usize, natural_drain_grace: Duration) -> Self {
        Self {
            reader: None,
            completion: None,
            #[cfg(unix)]
            cancel: None,
            tail: Arc::new(Mutex::new(Vec::with_capacity(limit))),
            natural_drain_grace,
        }
    }

    fn spawn_blocking<R>(
        pipe: Option<R>,
        limit: usize,
        natural_drain_grace: Duration,
    ) -> Self
    where
        R: Read + Send + 'static,
    {
        let Some(mut pipe) = pipe else {
            return Self::empty(limit, natural_drain_grace);
        };
        let tail = Arc::new(Mutex::new(Vec::with_capacity(limit)));
        let reader_tail = tail.clone();
        let (sender, receiver) = mpsc::sync_channel(1);
        let reader = std::thread::spawn(move || {
            let mut buffer = [0_u8; READ_BUFFER_BYTES];
            loop {
                match pipe.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => {
                        let mut current = reader_tail
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner());
                        append_tail(&mut current, &buffer[..count], limit);
                    }
                    Err(_) => break,
                }
            }
            let _ = sender.send(());
        });
        Self {
            reader: Some(reader),
            completion: Some(receiver),
            #[cfg(unix)]
            cancel: None,
            tail,
            natural_drain_grace,
        }
    }

    pub(crate) fn text(&self) -> String {
        let bytes = self
            .tail
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        String::from_utf8_lossy(&bytes).into_owned()
    }

    pub(crate) fn finish(mut self) -> String {
        self.stop_reader();
        self.text()
    }

    fn stop_reader(&mut self) {
        let mut completed = self.wait_for_completion(self.natural_drain_grace);
        if !completed {
            self.signal_cancel();
            completed = self.wait_for_completion(CANCEL_JOIN_GRACE);
        } else {
            self.signal_cancel();
        }
        self.completion.take();
        if completed {
            if let Some(reader) = self.reader.take() {
                let _ = reader.join();
            }
        } else {
            // Dropping an unfinished JoinHandle detaches it. This is only the
            // last-resort path when the platform cancellation primitive failed;
            // caller latency remains bounded.
            self.reader.take();
        }
    }

    fn wait_for_completion(&self, timeout: Duration) -> bool {
        let Some(receiver) = self.completion.as_ref() else {
            return true;
        };
        match receiver.recv_timeout(timeout) {
            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => true,
            Err(mpsc::RecvTimeoutError::Timeout) => false,
        }
    }

    #[cfg(unix)]
    fn signal_cancel(&mut self) {
        // Closing the self-pipe write end yields POLLHUP on the reader.
        drop(self.cancel.take());
    }

    #[cfg(windows)]
    fn signal_cancel(&mut self) {
        use std::os::windows::io::AsRawHandle;

        if let Some(reader) = self.reader.as_ref() {
            // SAFETY: the raw thread handle belongs to the live JoinHandle and
            // remains valid for this call. Failure is handled by the bounded
            // wait and detach fallback in stop_reader().
            unsafe {
                windows_sys::Win32::System::IO::CancelSynchronousIo(
                    reader.as_raw_handle() as _,
                );
            }
        }
    }

    #[cfg(all(not(unix), not(windows)))]
    fn signal_cancel(&mut self) {}
}

impl Drop for ProcessPipeTail {
    fn drop(&mut self) {
        self.stop_reader();
    }
}

fn append_tail(tail: &mut Vec<u8>, bytes: &[u8], limit: usize) {
    if limit == 0 {
        tail.clear();
        return;
    }
    if bytes.len() >= limit {
        tail.clear();
        tail.extend_from_slice(&bytes[(bytes.len() - limit)..]);
        return;
    }
    let overflow = tail
        .len()
        .saturating_add(bytes.len())
        .saturating_sub(limit);
    if overflow > 0 {
        tail.drain(..overflow);
    }
    tail.extend_from_slice(bytes);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn tail_keeps_only_the_requested_suffix() {
        let mut tail = b"prefix".to_vec();
        append_tail(&mut tail, b"-0123456789", 8);
        assert_eq!(tail, b"23456789");
    }

    #[test]
    fn blocking_reader_preserves_a_bounded_diagnostic_tail() {
        let marker = b"final-marker";
        let mut bytes = b"discarded-prefix".to_vec();
        bytes.extend(vec![b'x'; 128]);
        bytes.extend_from_slice(marker);
        let collector = ProcessPipeTail::spawn_blocking(
            Some(std::io::Cursor::new(bytes)),
            32,
            Duration::from_millis(50),
        );

        let tail = collector.finish();

        assert!(tail.len() <= 32);
        assert!(tail.ends_with("final-marker"));
        assert!(!tail.contains("discarded-prefix"));
    }

    #[test]
    fn missing_pipe_finishes_with_an_empty_tail() {
        let collector = ProcessPipeTail::spawn_blocking::<std::io::Cursor<Vec<u8>>>(
            None,
            32,
            Duration::from_millis(50),
        );
        assert!(collector.finish().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn cancellation_reaps_reader_while_writer_stays_alive() {
        let (read_end, write_end) = rustix::pipe::pipe().unwrap();
        rustix::io::write(&write_end, b"descendant tail").unwrap();
        let collector =
            ProcessPipeTail::spawn(Some(read_end), 64 * 1024, Duration::from_millis(50));

        let started_at = Instant::now();
        let tail = collector.finish();

        assert!(started_at.elapsed() < Duration::from_secs(1));
        assert_eq!(tail, "descendant tail");
        drop(write_end);
    }

    #[cfg(unix)]
    #[test]
    fn cancellation_preempts_a_continuously_ready_writer() {
        let (read_end, write_end) = rustix::pipe::pipe().unwrap();
        let collector =
            ProcessPipeTail::spawn(Some(read_end), 64 * 1024, Duration::from_millis(50));
        let (started_sender, started_receiver) = mpsc::sync_channel(1);
        let writer = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(2);
            let chunk = [b'x'; 64 * 1024];
            let mut announced = false;
            while Instant::now() < deadline {
                match rustix::io::write(&write_end, &chunk) {
                    Ok(_) => {
                        if !announced {
                            let _ = started_sender.send(());
                            announced = true;
                        }
                    }
                    Err(_) => break,
                }
            }
        });
        started_receiver
            .recv_timeout(Duration::from_secs(1))
            .expect("continuous writer should first confirm a successful write");

        let started_at = Instant::now();
        let tail = collector.finish();
        let elapsed = started_at.elapsed();
        writer.join().unwrap();

        assert!(
            elapsed < Duration::from_millis(1_500),
            "cancellation waited for writer shutdown: {elapsed:?}"
        );
        assert!(!tail.is_empty());
        assert!(tail.len() <= 64 * 1024);
    }
}
