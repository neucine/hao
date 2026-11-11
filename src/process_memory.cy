import { native_snapshot } from .bridge.host;

pub struct Snapshot {
    pub resident_bytes: u64;
    pub physical_footprint_bytes: u64;
}

pub fn snapshot(): Snapshot {
    var values: [2]c_ullong = [0, 0];
    const view = values[..];
    const base = view.ptr as! *c_ullong;
    unchecked { native_snapshot(base, base + 1); }
    return Snapshot {
        resident_bytes: values[0] as u64,
        physical_footprint_bytes: values[1] as u64,
    };
}

pub fn snapshot_c(resident: *c_ullong, footprint: *c_ullong): void {
    const value = snapshot();
    unchecked {
        *resident = value.resident_bytes as c_ullong;
        *footprint = value.physical_footprint_bytes as c_ullong;
    }
}
