import { allocate as native_allocate, free as native_free } from .bridge.host;

pub fn allocate(size: c_size_t): *c_void { return native_allocate(size); }
pub fn free(pointer: *c_void): void { native_free(pointer); }
