import { run_turn } from .async.uv;

extern c("hao_runtime_drain") fn runtime_drain(handle: c_size_t): c_int;

pub struct Loop {
    pub handle: c_size_t;

    pub fn drain_jobs(self: &const Loop): i32 {
        return runtime_drain(self.handle) as i32;
    }

    pub fn run_turn(self: &const Loop): i32 {
        return run_turn(self.handle);
    }

    pub fn run_until_idle(self: &const Loop): i32 {
        var active = true;
        var status: i32 = 0;
        while active {
            const ran_jobs = self.drain_jobs();
            if ran_jobs < 0 {
                status = 1;
                active = false;
            } else {
                const ran_io = self.run_turn();
                if ran_io < 0 {
                    status = 1;
                    active = false;
                } else if ran_jobs == 0 and ran_io == 0 {
                    active = false;
                }
            }
        }
        return status;
    }
}
