import { args } from std.process;
import { read_file } from std.fs;
import { Runtime } from .runtime;
import { install } from .std_modules;

fn main(): i32 {
    const arguments = args();
    if arguments.len() != 2 {
        println("Usage: hao <file.js>");
        return 2;
    }
    const path = arguments[1];
    if path == "--version" or path == "-v" {
        println("hao 0.1.2 (Cyna runtime preview)");
        return 0;
    }
    const source = read_file(path) catch (code) {
        println("Unable to read script");
        return 1;
    };
    const runtime = Runtime.init();
    if runtime is host {
        defer host.deinit();
        if install(&host) != 0 {
            println("Unable to install standard modules");
            return 1;
        }
        const status = host.eval(source, path);
        if status != 0 {
            return status;
        }
        return host.run_until_idle();
    }
    println("Unable to initialize JavaScript runtime");
    return 1;
}
