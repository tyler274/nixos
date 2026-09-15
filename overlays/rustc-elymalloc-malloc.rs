//! jemalloc-sys `override_allocator_on_supported_platforms` equivalent.
//!
//! rustc's jemalloc is not `#[global_allocator]`; it statically overrides
//! libc `malloc`/`free` so `std::alloc::System` (and C in the same image)
//! all hit the same heap. These `#[no_mangle]` symbols live in libstd, so
//! every Rust bin/cdylib that links std embeds ElyMalloc the same way.
//!
//! Match ElyMalloc's cdylib: malloc family only (no `strdup`/`reallocarray`).

use core::ffi::c_void;
use elymalloc_core::alloc as mi;

#[no_mangle]
pub unsafe extern "C" fn malloc(size: usize) -> *mut c_void {
    unsafe { mi::malloc(size) as *mut c_void }
}

#[no_mangle]
pub unsafe extern "C" fn calloc(count: usize, size: usize) -> *mut c_void {
    unsafe { mi::calloc(count, size) as *mut c_void }
}

#[no_mangle]
pub unsafe extern "C" fn realloc(p: *mut c_void, newsize: usize) -> *mut c_void {
    unsafe { mi::realloc(p as *mut u8, newsize) as *mut c_void }
}

#[no_mangle]
pub unsafe extern "C" fn free(p: *mut c_void) {
    unsafe { mi::free(p as *mut u8) }
}

#[no_mangle]
pub unsafe extern "C" fn posix_memalign(
    p: *mut *mut c_void,
    alignment: usize,
    size: usize,
) -> i32 {
    unsafe { mi::posix_memalign(p as *mut *mut u8, alignment, size) }
}

#[no_mangle]
pub unsafe extern "C" fn aligned_alloc(alignment: usize, size: usize) -> *mut c_void {
    unsafe { mi::aligned_alloc(alignment, size) as *mut c_void }
}

#[no_mangle]
pub unsafe extern "C" fn memalign(alignment: usize, size: usize) -> *mut c_void {
    unsafe { mi::memalign(alignment, size) as *mut c_void }
}

#[used]
static KEEP_MALLOC_OVERRIDE: [unsafe extern "C" fn(usize) -> *mut c_void; 1] = [malloc];
