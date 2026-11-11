"""Compare the plain test reporter and hook behavior of two Hao binaries."""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


CASES = {
    "before-all": '''import {describe,test,beforeAll,afterAll} from "std:test";
describe("s",()=>{beforeAll(()=>{throw Error("setup")});afterAll(()=>console.log("cleanup"));test("a",()=>{});test("b",()=>{})});''',
    "after-all": '''import {describe,test,afterAll} from "std:test";
describe("s",()=>{afterAll(()=>{throw Error("teardown")});test("a",()=>{})});''',
    "before-each": '''import {describe,test,beforeEach,afterEach} from "std:test";
describe("a",()=>{beforeEach(()=>console.log("outer"));afterEach(()=>console.log("outer cleanup"));describe("b",()=>{beforeEach(()=>{throw Error("setup")});afterEach(()=>console.log("inner cleanup"));test("case",()=>console.log("body"))})});''',
    "after-each": '''import {describe,test,afterEach} from "std:test";
describe("s",()=>{afterEach(()=>{throw Error("first")});afterEach(()=>{throw Error("second")});test("case",()=>{throw Error("body")})});''',
    "async-hooks": '''import {describe,test,beforeAll,afterAll,beforeEach,afterEach} from "std:test";
describe("s",()=>{beforeAll(async()=>{await Promise.resolve();console.log("before")});beforeEach(async()=>{await Promise.resolve();console.log("each")});afterEach(async()=>{await Promise.resolve();console.log("after each")});afterAll(async()=>{await Promise.resolve();console.log("after")});test("case",async()=>{await Promise.resolve();console.log("body")})});''',
    "modes": '''import {describe,test,beforeAll,afterAll} from "std:test";
describe("ordinary",()=>{beforeAll(()=>console.log("ordinary before"));afterAll(()=>console.log("ordinary after"));test("alpha",()=>console.log("alpha"));test.skip("needle skip",()=>console.log("bad"))});
describe.only("focused",()=>{beforeAll(()=>console.log("focused before"));afterAll(()=>console.log("focused after"));test("needle one",()=>console.log("one"));test.skip("needle skipped",()=>console.log("bad"));test.only("needle two",()=>console.log("two"))});
describe.skip("blocked",()=>{beforeAll(()=>console.log("blocked before"));test("needle three",()=>console.log("bad"))});''',
}


def outcome(binary: Path, source: Path, grep: str | None) -> tuple[int, str, str]:
    args = [str(binary), "test"]
    if grep is not None:
        args += ["--grep", grep]
    args.append(str(source))
    result = subprocess.run(
        args, capture_output=True, text=True,
        env={**os.environ, "RUNTIME_TEST_REPORTER": "plain"}, timeout=15,
    )
    report = re.sub(r"Time: .*", "Time: <time>", result.stderr)
    report = re.sub(r"\(\d+(?:\.\d+)?(?:ns|us|ms|s)\)", "(<time>)", report)
    return result.returncode, result.stdout, report


def main() -> None:
    legacy, port = (Path(arg).resolve() for arg in sys.argv[1:3])
    with tempfile.TemporaryDirectory(prefix="hao-runner-differential-") as directory:
        for name, text in CASES.items():
            source = Path(directory) / f"{name}.test.ts"
            source.write_text(text)
            variants = [None, "needle", "alpha", "nope"] if name == "modes" else [None]
            for grep in variants:
                expected = outcome(legacy, source, grep)
                actual = outcome(port, source, grep)
                assert actual == expected, (name, grep, expected, actual)
    print("Runner differential: 9 cases matched")


if __name__ == "__main__":
    main()
