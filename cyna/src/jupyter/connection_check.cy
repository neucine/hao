import { args } from std.process;
import { parse } from .jupyter.connection;

fn main(): i32 {
    const arguments = args();
    if arguments.len() != 2 {
        return 2;
    }
    if parse(arguments[1].clone()) is connection {
        println(connection.endpoint(connection.shell_port));
        println(connection.key);
        println(connection.signature_scheme);
        return 0;
    }
    return 1;
}
