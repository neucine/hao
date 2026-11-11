pub extern c("hao_alloc") fn allocate(size: c_size_t): *c_void;
pub extern c("hao_free") fn free(pointer: *c_void): void;
