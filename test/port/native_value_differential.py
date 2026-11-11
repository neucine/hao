"""Compare util inspection and process limit conversion with legacy Hao."""

from pathlib import Path
import subprocess
import sys
import tempfile


REPR_VALUES = [
    "null", "undefined", "true", "false", "0", "-1", "1.25", "NaN",
    "Infinity", "1n", '"abc"', '"é😀"', 'Symbol("x")', "[]", "[1,2]",
    "{}", "{data:null}", "{data:undefined}", "{data:true}",
    "{data:false}", "{data:0}", "{data:-1}", "{data:1.25}",
    "{data:NaN}", "{data:Infinity}", "{data:1n}", '{data:"abc"}',
    '{data:"é😀"}', '{data:Symbol("x")}',
    '{get data(){throw Error("getter")}}',
]
STRING_LIMITS = [
    "undefined", "{maxStringLength:0}", "{maxStringLength:1}",
    "{maxStringLength:2}", "{maxStringLength:3}",
    "{maxStringLength:4}", "{maxStringLength:5}",
]
OUTPUT_LIMITS = [
    "undefined", "null", "0", "1", "2", "-1", "-2", "1.2", "-1.2",
    "NaN", "Infinity", "-Infinity", "2147483647", "2147483648",
    "4294967295", "4294967296", '"2"', '"0"', '"abc"', "true",
    "false", "1n", 'Symbol("x")', "{valueOf(){return 2}}",
    '{valueOf(){throw Error("bad")}}',
]


def run(binary: Path, source: Path) -> tuple[int, str, str]:
    result = subprocess.run([str(binary), str(source)], capture_output=True,
                            text=True, timeout=15)
    return result.returncode, result.stdout, result.stderr


def main() -> None:
    legacy, port = (Path(value).resolve() for value in sys.argv[1:3])
    with tempfile.TemporaryDirectory(prefix="hao-native-value-differential-") as directory:
        source = Path(directory) / "values.ts"
        lines = ['import { inspect } from "std:util";']
        for value in REPR_VALUES:
            for limit in STRING_LIMITS:
                lines.append(
                    f'console.log(JSON.stringify(inspect({{repr(){{return {value}}},a:1}}, {limit})));'
                )
        source.write_text("\n".join(lines))
        assert run(port, source) == run(legacy, source), "util repr matrix differs"

        lines = ['import { runNative } from "std:process/native";']
        for limit in OUTPUT_LIMITS:
            lines.append(
                'try { const result = runNative({cmd:"/bin/echo",args:["abc"],'
                f'maxOutputBytes:{limit}}}); console.log(JSON.stringify(result)); }} '
                'catch (error) { console.log(error.name + ":" + error.message); }'
            )
        source.write_text("\n".join(lines))
        assert run(port, source) == run(legacy, source), "process output limit matrix differs"
    print("Native value differential: 235 cases matched")


if __name__ == "__main__":
    main()
