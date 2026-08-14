//! Launch-time concerns: keeping Free Scribe to one running copy, and reporting a
//! failure that happens before there is a window to report it in.
//!
//! Both exist because of the global shortcut. `RegisterHotKey` is machine-wide, so a
//! second copy cannot have hold-to-talk; and release builds detach the console (see
//! `windows_subsystem` in `main.rs`), so anything written to stderr there is
//! invisible — a dialog is the only thing the user actually sees.

/// Proof that this process is the running copy of Free Scribe. Hold it for as long as
/// the app runs; dropping it lets the next launch through.
pub struct InstanceLock {
    /// Never read: the lock is the handle being open, and it is released on drop.
    _guard: platform::Guard,
}

/// Asks for the right to be the running copy. `None` means another one already has
/// it and has been brought to the front instead, so this process should just leave.
pub fn claim_instance() -> Option<InstanceLock> {
    platform::claim().map(|_guard| InstanceLock { _guard })
}

/// Tells the user why the app is not opening. Goes to stderr as well as to a dialog,
/// since stderr is what a debug build or a redirected release build can capture.
pub fn report_fatal(message: &str) {
    eprintln!("{message}");
    platform::alert(message);
}

#[cfg(windows)]
mod platform {
    use windows::core::{w, HSTRING, PCWSTR};
    use windows::Win32::Foundation::{
        CloseHandle, GetLastError, HANDLE, ERROR_ALREADY_EXISTS,
    };
    use windows::Win32::System::Threading::CreateMutexW;
    use windows::Win32::UI::WindowsAndMessaging::{
        FindWindowW, MessageBoxW, SetForegroundWindow, ShowWindow, MB_ICONERROR, MB_ICONINFORMATION,
        MB_OK, SW_RESTORE,
    };

    /// `Local\` rather than `Global\`, so a second signed-in user gets their own copy
    /// rather than being told Free Scribe is already running by someone else.
    const MUTEX_NAME: PCWSTR = w!(r"Local\local.freescribe.app.instance");

    /// The native window title, from `tauri.conf.json`.
    const WINDOW_TITLE: PCWSTR = w!("Free Scribe");

    pub struct Guard(HANDLE);

    impl Drop for Guard {
        fn drop(&mut self) {
            if !self.0.is_invalid() {
                // SAFETY: the handle came from `CreateMutexW` and is closed once.
                let _ = unsafe { CloseHandle(self.0) };
            }
        }
    }

    pub fn claim() -> Option<Guard> {
        // SAFETY: a named mutex with default security; the handle is closed on drop.
        let Ok(handle) = (unsafe { CreateMutexW(None, false, MUTEX_NAME) }) else {
            // Without the mutex there is no way to tell. Starting is the kinder guess:
            // the worst case is a second window, not a machine with no dictation.
            return Some(Guard(HANDLE::default()));
        };

        // The handle is valid whether or not we are the one who created the mutex;
        // the last error is the only thing that distinguishes the two.
        // SAFETY: reads the calling thread's last error, set by the call above.
        let already_running = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
        let guard = Guard(handle);

        if already_running {
            focus_running_copy();
            return None;
        }

        Some(guard)
    }

    /// Raises the window of the copy that is already running, which is what the user
    /// launching the app a second time is usually asking for.
    fn focus_running_copy() {
        // SAFETY: plain window lookup; a missing window comes back as an error.
        let Ok(window) = (unsafe { FindWindowW(None, WINDOW_TITLE) }) else {
            // It is running but has no window we can find — say so rather than
            // vanishing with no explanation.
            alert_with(
                "Free Scribe is already running.",
                MB_OK | MB_ICONINFORMATION,
            );
            return;
        };

        // SAFETY: `window` is a live handle from `FindWindowW`.
        unsafe {
            let _ = ShowWindow(window, SW_RESTORE);
            let _ = SetForegroundWindow(window);
        }
    }

    pub fn alert(message: &str) {
        alert_with(message, MB_OK | MB_ICONERROR);
    }

    fn alert_with(message: &str, style: windows::Win32::UI::WindowsAndMessaging::MESSAGEBOX_STYLE) {
        // SAFETY: both strings outlive the modal call.
        unsafe {
            MessageBoxW(None, &HSTRING::from(message), WINDOW_TITLE, style);
        }
    }
}

/// Non-Windows builds exist only so the crate compiles for local checking; the
/// shipped macOS app is the Swift one.
#[cfg(not(windows))]
mod platform {
    pub struct Guard;

    pub fn claim() -> Option<Guard> {
        Some(Guard)
    }

    pub fn alert(_message: &str) {}
}
