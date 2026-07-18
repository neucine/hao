const shared = @import("zig_libs").telemetry.metrics;

pub const max_metrics = shared.max_metrics;
pub const Id = shared.Id;
pub const Kind = shared.Kind;
pub const Definition = shared.Definition;
pub const Snapshot = shared.Snapshot;

pub const init = shared.init;
pub const register = shared.register;
pub const add = shared.add;
pub const set = shared.set;
pub const observe = shared.observe;
pub const value = shared.value;
pub const snapshot = shared.snapshot;
pub const clear = shared.clear;
