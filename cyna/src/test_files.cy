import { read_dir, exists, DirEntryKind } from std.fs;
import { join } from std.path;

pub fn collect(path: string, files: &List<string>): i32 {
    if path.ends_with(".test.ts") {
        files.push(path);
        return 0;
    }
    const entries = read_dir(path.clone()) catch (code) {
        const present = exists(path.clone()) catch (error) { return 1; };
        if present {
            files.push(path);
            return 0;
        }
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

fn path_less(left: &const string, right: &const string): bool {
    const a = left.bytes();
    const b = right.bytes();
    var index: usize = 0;
    while index < a.len() and index < b.len() {
        if a[index] != b[index] {
            return a[index] < b[index];
        }
        index = index + 1;
    }
    return a.len() < b.len();
}

pub fn sort(files: &List<string>): void {
    var index: usize = 1;
    while index < files.len() {
        var cursor = index;
        while cursor > 0 and path_less(&files[cursor], &files[cursor - 1]) {
            const previous = files[cursor - 1].clone();
            files[cursor - 1] = files[cursor].clone();
            files[cursor] = previous;
            cursor = cursor - 1;
        }
        index = index + 1;
    }
}
