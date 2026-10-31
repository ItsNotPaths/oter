//! hatchzip-core's listing behind a C ABI, for oter's Odin side.

use std::ffi::{CStr, CString, c_char, c_int};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::Arc;

use hatchzip_core::archive::{self, Kind, PasswordNeeded, storage::Storage};

pub const HZ_OK: c_int = 0;
pub const HZ_NOT_ARCHIVE: c_int = 1;
pub const HZ_PASSWORD: c_int = 2;

#[repr(C)]
pub struct HzItem {
    pub path: *mut c_char,
    pub is_dir: bool,
}

#[repr(C)]
pub struct HzList {
    pub items: *mut HzItem,
    pub count: usize,
}

/// Lists the archive at `path` into `out`, which `hz_free` releases. Read-only.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hz_list(path: *const c_char, out: *mut HzList) -> c_int {
    let path = Path::new(std::ffi::OsStr::from_bytes(unsafe { CStr::from_ptr(path) }.to_bytes()));
    let opened = match Storage::open(path, false).and_then(|s| archive::open(&Arc::new(s), None, None)) {
        Ok(o) => o,
        Err(e) if e.chain().any(|c| c.is::<PasswordNeeded>()) => return HZ_PASSWORD,
        Err(_) => return HZ_NOT_ARCHIVE,
    };
    let mut items: Vec<HzItem> = opened
        .units
        .iter()
        .flat_map(|u| &u.items)
        .filter_map(|i| {
            Some(HzItem {
                path: CString::new(i.path.as_os_str().as_bytes()).ok()?.into_raw(),
                is_dir: i.kind == Kind::Dir,
            })
        })
        .collect();
    items.shrink_to_fit(); // hz_free rebuilds the Vec from count alone
    let count = items.len();
    unsafe {
        *out = HzList { items: items.as_mut_ptr(), count };
    }
    std::mem::forget(items);
    HZ_OK
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hz_free(list: *mut HzList) {
    let list = unsafe { &mut *list };
    if list.items.is_null() {
        return;
    }
    let items = unsafe { Vec::from_raw_parts(list.items, list.count, list.count) };
    for i in items {
        drop(unsafe { CString::from_raw(i.path) });
    }
    *list = HzList { items: std::ptr::null_mut(), count: 0 };
}
