//! hatchzip-core's listing and extraction behind a C ABI, for oter's Odin side.

use std::ffi::{CStr, CString, OsStr, c_char, c_int, c_void};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Result, bail};
use hatchzip_core::archive::{self, Item, Kind, PasswordNeeded, Sink, storage::Storage};

pub const HZ_OK: c_int = 0;
pub const HZ_NOT_ARCHIVE: c_int = 1;
pub const HZ_PASSWORD: c_int = 2;

pub const HZ_PROGRESS: c_int = 0;
pub const HZ_DONE: c_int = 1;
pub const HZ_SKIPPED: c_int = 2;

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

/// `(ctx, pick index, percent by bytes, HZ_PROGRESS | HZ_DONE | HZ_SKIPPED)`.
pub type Report = extern "C" fn(*mut c_void, usize, u8, c_int);

unsafe fn path<'a>(p: *const c_char) -> &'a Path {
    Path::new(OsStr::from_bytes(unsafe { CStr::from_ptr(p) }.to_bytes()))
}

fn open(path: &Path) -> Result<archive::Opened> {
    archive::open(&Arc::new(Storage::open(path, false)?), None, None)
}

/// Lists the archive at `path` into `out`, which `hz_free` releases. Read-only.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hz_list(path: *const c_char, out: *mut HzList) -> c_int {
    let opened = match open(unsafe { self::path(path) }) {
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

/// Extracts each `picks[i]`, a file or a dir's whole tree, to `dst_dir/<its base name>`.
/// One already there is skipped. Returns null, or an error for `hz_free_str`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hz_extract(
    archive: *const c_char,
    picks: *const *const c_char,
    n: usize,
    dst_dir: *const c_char,
    report: Report,
    ctx: *mut c_void,
) -> *mut c_char {
    let picks: Vec<&Path> = (0..n).map(|i| unsafe { path(*picks.add(i)) }).collect();
    let mut report = |i, pct, state| report(ctx, i, pct, state);
    match extract(unsafe { path(archive) }, &picks, unsafe { path(dst_dir) }, &mut report) {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => CString::new(format!("{e:#}")).unwrap_or_default().into_raw(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn hz_free_str(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

struct Pick<'a> {
    inner: &'a Path,
    base: &'a Path, // its parent: what is cut off to place an item under dst
    skipped: bool,
    total: u64,
    written: u64,
    pct: u8,
}

struct Extract<'a, 'r> {
    picks: Vec<Pick<'a>>,
    dst: &'a Path,
    report: &'r mut dyn FnMut(usize, u8, c_int),
    links: Vec<(PathBuf, Kind, PathBuf)>, // made last, so no file is written through one
}

impl Extract<'_, '_> {
    fn owner(&self, p: &Path) -> Option<usize> {
        self.picks.iter().position(|k| !k.skipped && p.starts_with(k.inner))
    }

    fn out(&self, i: usize, p: &Path) -> PathBuf {
        self.dst.join(p.strip_prefix(self.picks[i].base).unwrap_or(p))
    }
}

impl Sink for Extract<'_, '_> {
    fn item(&mut self, item: &Item, data: &mut dyn Read) -> Result<()> {
        let Some(i) = self.owner(&item.path) else {
            io::copy(data, &mut io::sink())?;
            return Ok(());
        };
        let out = self.out(i, &item.path);
        match &item.kind {
            Kind::Dir => fs::create_dir_all(&out)?,
            Kind::Symlink => {
                let mut target = Vec::new();
                data.read_to_end(&mut target)?;
                self.links.push((out, Kind::Symlink, PathBuf::from(OsStr::from_bytes(&target))));
            }
            Kind::HardLink(to) => {
                if let Some(j) = self.owner(to) {
                    let to = self.out(j, to);
                    self.links.push((out, item.kind.clone(), to));
                }
            }
            Kind::File => {
                if let Some(dir) = out.parent() {
                    fs::create_dir_all(dir)?;
                }
                let mut f = File::create_new(&out)?;
                let mut buf = vec![0u8; 1 << 18];
                loop {
                    let n = data.read(&mut buf)?;
                    if n == 0 {
                        break;
                    }
                    f.write_all(&buf[..n])?;
                    let p = &mut self.picks[i];
                    p.written += n as u64;
                    let pct = (p.written * 100 / p.total.max(1)).min(100) as u8;
                    if pct != p.pct {
                        p.pct = pct;
                        (self.report)(i, pct, HZ_PROGRESS);
                    }
                }
                if let Some(mode) = item.mode {
                    f.set_permissions(fs::Permissions::from_mode(mode & 0o7777))?;
                }
                if let Some(t) = item.mtime {
                    f.set_modified(t)?;
                }
            }
        }
        Ok(())
    }
}

fn extract(archive: &Path, picks: &[&Path], dst: &Path, report: &mut dyn FnMut(usize, u8, c_int)) -> Result<()> {
    let opened = open(archive)?;
    let mut x = Extract {
        picks: picks
            .iter()
            .map(|&inner| Pick {
                inner,
                base: inner.parent().unwrap_or(Path::new("")),
                skipped: false,
                total: 0,
                written: 0,
                pct: 0,
            })
            .collect(),
        dst,
        report,
        links: Vec::new(),
    };
    for (i, p) in x.picks.iter_mut().enumerate() {
        let name = p.inner.file_name().unwrap_or_default();
        if dst.join(name).symlink_metadata().is_ok() {
            p.skipped = true;
            (x.report)(i, 0, HZ_SKIPPED);
        }
    }
    let items = opened.units.iter().flat_map(|u| &u.items);
    for item in items.clone() {
        if let Some(i) = x.owner(&item.path) {
            x.picks[i].total += item.size;
        }
    }
    for p in x.picks.iter().filter(|p| !p.skipped) {
        if !items.clone().any(|it| it.path.starts_with(p.inner)) {
            bail!("{} is not in the archive", p.inner.display());
        }
    }

    // Serial formats need the lowest unit first; the rest don't mind.
    let mut units: Vec<_> = opened
        .units
        .iter()
        .filter(|u| u.items.iter().any(|it| x.owner(&it.path).is_some()))
        .collect();
    units.sort_by_key(|u| u.start);
    let mut worker = opened.format.worker(1)?;
    for u in units {
        worker.extract(u, &mut x)?;
    }

    for (out, kind, to) in std::mem::take(&mut x.links) {
        match kind {
            Kind::Symlink => std::os::unix::fs::symlink(&to, &out)?,
            _ => fs::hard_link(&to, &out)?,
        }
    }
    for i in 0..x.picks.len() {
        if !x.picks[i].skipped {
            (x.report)(i, 100, HZ_DONE);
        }
    }
    Ok(())
}
