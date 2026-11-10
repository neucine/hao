import { read_dir, DirEntryKind } from std.fs;
import { join } from std.path;

pub fn collect(path: string, files: &List<string>): i32 {
    if path.ends_with(".test.ts") {
        files.push(path);
        return 0;
    }
    const entries = read_dir(path.clone()) catch (code) {
        return 1;
    };
    for entry in entries {
        const parts: [2]string = [path.clone(), entry.name.clone()];
        const child = join(parts[..]);
        if entry.kind == DirEntryKind.dir {
            if collect(child, files) != 0 {
                return 1;
            }
        } else if entry.kind == DirEntryKind.file and child.ends_with(".test.ts") {
            files.push(child);
        }
    }
    return 0;
}
