//! Puts the transcript into whatever app the user is actually typing in.
//! The macOS equivalent is `Paste.swift`; here the keystroke goes through
//! `SendInput` instead of `CGEvent`.

use arboard::Clipboard;

/// Copies `text` and presses Ctrl+V in the foreground window. Returns false when it
/// could only copy — the caller should tell the user the text is on the clipboard
/// rather than pretend it worked.
pub fn insert(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }

    let Ok(mut clipboard) = Clipboard::new() else {
        return false;
    };

    // ponytail: plain text only, same as the macOS build. If someone loses a copied
    // image to a dictation, snapshot the other clipboard formats here.
    let previous = clipboard.get_text().ok();

    if clipboard.set_text(text.to_owned()).is_err() {
        return false;
    }

    let pasted = send_paste_keystroke();

    if let Some(previous) = previous {
        // Give the target app time to read the clipboard before putting it back.
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(250));
            if let Ok(mut clipboard) = Clipboard::new() {
                let _ = clipboard.set_text(previous);
            }
        });
    }

    pasted
}

#[cfg(windows)]
fn send_paste_keystroke() -> bool {
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS,
        KEYEVENTF_KEYUP, VIRTUAL_KEY, VK_CONTROL, VK_V,
    };

    fn key(code: VIRTUAL_KEY, flags: KEYBD_EVENT_FLAGS) -> INPUT {
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: code,
                    wScan: 0,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        }
    }

    let inputs = [
        key(VK_CONTROL, KEYBD_EVENT_FLAGS(0)),
        key(VK_V, KEYBD_EVENT_FLAGS(0)),
        key(VK_V, KEYEVENTF_KEYUP),
        key(VK_CONTROL, KEYEVENTF_KEYUP),
    ];

    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    sent as usize == inputs.len()
}

/// Non-Windows builds exist only so the crate compiles for local checking; the
/// shipped macOS app is the Swift one.
#[cfg(not(windows))]
fn send_paste_keystroke() -> bool {
    false
}

/// Windows has no Accessibility gate for synthetic input, so unlike macOS there is
/// nothing to request. UIPI still blocks sending input to a window running at a
/// higher integrity level, which is the one case where pasting silently fails.
pub fn needs_permission() -> bool {
    false
}
