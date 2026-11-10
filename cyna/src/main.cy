import { args, exe_path } from std.process;
import { read_file } from std.fs;
import { Runtime } from .runtime;
import { install } from .std_modules;
import { collect } from .test_files;
import { load_dotenv } from .config;
import { run as run_jupyter } from .jupyter;

fn run_file(host: &const Runtime, path: string): i32 {
    const source = read_file(path.clone()) catch (code) {
        println("Unable to read script");
        return 1;
    };
    return host.eval(source, path);
}

fn main(): i32 {
    if load_dotenv() != 0 {
        println("Unable to load dotenv file");
        return 1;
    }
    const arguments = args();
    if arguments.len() < 2 {
        println("Usage: hao <file.ts> | hao test [--grep pattern] <file-or-dir>... | hao jupyter --connection-file <file>");
        return 2;
    }
    if arguments.len() == 2 and (arguments[1] == "--version" or arguments[1] == "-v") {
        println("hao 0.1.2 (Cyna runtime preview)");
        return 0;
    }
    if arguments[1] == "jupyter" {
        if arguments.len() == 4 and arguments[2] == "--connection-file" {
            return run_jupyter(arguments[3].clone());
        }
        println("Usage: hao jupyter --connection-file <file>");
        return 2;
    }
    const is_test = arguments[1] == "test";
    if not is_test and arguments.len() != 2 {
        println("Usage: hao <file.ts> | hao test [--grep pattern] <file-or-dir>... | hao jupyter --connection-file <file>");
        return 2;
    }
    var test_files: List<string> = list<string>();
    var grep = "";
    if is_test {
        var index: usize = 2;
        while index < arguments.len() {
            if arguments[index] == "--grep" {
                if index + 1 >= arguments.len() {
                    println("--grep requires a pattern");
                    return 2;
                }
                grep = arguments[index + 1].clone();
                index = index + 2;
            } else {
                if collect(arguments[index].clone(), &test_files) != 0 {
                    println("Unable to discover test files");
                    return 1;
                }
                index = index + 1;
            }
        }
        if test_files.len() == 0 {
            println("No test files found");
            return 1;
        }
    }
    const runtime = Runtime.init();
    if runtime is host {
        defer host.deinit();
        if install(&host) != 0 {
            println("Unable to install standard modules");
            return 1;
        }
        if is_test {
            const executable = exe_path() catch (code) {
                println("Unable to find Hao executable");
                return 1;
            };
            if host.set_executable_path(executable) != 0 {
                return 1;
            }
            for path in test_files {
                if run_file(&host, path.clone()) != 0 {
                    return 1;
                }
            }
            if host.start_tests(grep) != 0 {
                return 1;
            }
        } else {
            if run_file(&host, arguments[1].clone()) != 0 {
                return 1;
            }
        }
        const loop_status = host.run_until_idle();
        if loop_status != 0 {
            return loop_status;
        }
        if is_test and host.test_failures() != 0 {
            return 1;
        }
        return 0;
    }
    println("Unable to initialize JavaScript runtime");
    return 1;
}
