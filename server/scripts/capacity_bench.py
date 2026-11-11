"""Run the Project C measurement on the existing local PostgreSQL server."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import tempfile
import time

SERVER = Path(__file__).resolve().parents[1]
DATABASE = "feud_hall_bench"
RSS_LIMIT_KIB = 2 * 1024 * 1024


def postgres_cli():
    psql = shutil.which("psql") or "/opt/homebrew/opt/postgresql@18/bin/psql"
    bin_dir = Path(psql).resolve().parent
    if not all((bin_dir / name).is_file() for name in ("createdb", "dropdb")):
        raise SystemExit("Put the system PostgreSQL bin directory on PATH.")
    return bin_dir


def rss_kib():
    rows = subprocess.check_output(["ps", "-axo", "pid=,rss=,comm="], text=True)
    memory = {"beam": 0, "postgres": 0, "runner": 0}
    for line in rows.splitlines():
        pid, rss, command = line.strip().split(maxsplit=2)
        name = Path(command).name
        if name == "beam.smp":
            memory["beam"] += int(rss)
        elif name == "postgres" or name.startswith("postgres:"):
            memory["postgres"] += int(rss)
        elif int(pid) == os.getpid():
            memory["runner"] = int(rss)
    return memory


def fingerprint():
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "server/lib", "server/priv",
         "server/config/dev.exs", "server/config/config.exs", "server/mix.exs",
         "server/mix.lock", "server/.tool-versions"],
        cwd=SERVER.parent,
    ).decode().split("\0")
    paths = [SERVER.parent / path for path in paths if path]
    paths += [SERVER / "scripts" / name for name in ("capacity_bench.py", "capacity_bench.exs", "capacity_restore.exs")]
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(SERVER)).encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


def measure(days, report, env, mode):
    command = ["mix", "run", "--no-start", "scripts/capacity_bench.exs", str(days), str(report), mode]
    peak = {}
    peak_engine = 0
    maximum = 0
    with subprocess.Popen(command, cwd=SERVER, env=env, start_new_session=True) as child:
        try:
            while True:
                memory = rss_kib()
                total = sum(memory.values())
                peak_engine = max(peak_engine, memory["beam"] + memory["postgres"])
                if total > maximum:
                    maximum, peak = total, memory
                if total > RSS_LIMIT_KIB:
                    raise RuntimeError(f"Memory limit exceeded at {total:,} KiB combined RSS")
                status = child.poll()
                if status is not None:
                    if status:
                        raise subprocess.CalledProcessError(status, command)
                    break
                time.sleep(1)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
    return {"peak_kib": maximum, "peak_sample_kib": peak, "peak_beam_postgres_kib": peak_engine,
            "limit_kib": RSS_LIMIT_KIB, "interval_seconds": 1}


def restore_archive(bin_dir, common, env, scratch):
    clone = DATABASE + "_restore"
    backup = scratch / "capacity.dump"
    connection = ["--host=localhost", "--port=5432", "--no-password"]

    def inspect(database, mode):
        output = subprocess.check_output(
            ["mix", "run", "--no-start", "scripts/capacity_restore.exs", database, mode],
            cwd=SERVER, env=env, text=True, timeout=300,
        )
        return json.loads(next(line.removeprefix("ARCHIVE_REPORT ") for line in output.splitlines()
                               if line.startswith("ARCHIVE_REPORT ")))

    source = inspect(DATABASE, "observe")
    started = time.monotonic()
    subprocess.run([bin_dir / "pg_dump", *connection, "--format=custom", "--file", backup, DATABASE],
                   check=True, env=env, timeout=300)
    dump_ms = round((time.monotonic() - started) * 1000)
    subprocess.run([bin_dir / "createdb", *common, "--template=template0", clone],
                   check=True, env=env, timeout=30)
    try:
        started = time.monotonic()
        subprocess.run([bin_dir / "pg_restore", *connection, "--exit-on-error", "--dbname", clone, backup],
                       check=True, env=env, timeout=300)
        restore_ms = round((time.monotonic() - started) * 1000)
        restored = inspect(clone, "rebuild")
        for key in ("head", "stream_versions", "tables", "state_sha256", "projections_sha256"):
            if source[key] != restored[key]:
                raise RuntimeError(f"Restored archive differs in {key}")
        return {"backup_bytes": backup.stat().st_size, "dump_ms": dump_ms, "restore_ms": restore_ms,
                "restored": restored}
    finally:
        subprocess.run([bin_dir / "dropdb", *common, clone], check=True, env=env, timeout=30)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, choices=range(1, 8), default=3)
    parser.add_argument("--mode", choices=("slice", "launch"), default="slice")
    parser.add_argument("--restore", action="store_true", help="Restore the disposable database and rebuild its projections")
    parser.add_argument("--output", type=Path, required=True, help="New JSON report path")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or not output.parent.is_dir():
        parser.error("Output must be a new file in an existing directory.")

    bin_dir = postgres_cli()
    env = {**os.environ, "PGHOST": "localhost", "PGPORT": "5432", "MIX_ENV": "dev", "FEUD_HALL_SERVE": "0",
           "FEUD_HALL_CAPACITY_DATABASE": DATABASE}
    env.pop("DATABASE_URL", None)
    common = ["--host=localhost", "--port=5432", "--maintenance-db=postgres", "--no-password"]
    source = fingerprint()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=SERVER, text=True).strip()
    signal.signal(signal.SIGTERM, interrupt)

    with tempfile.TemporaryDirectory(prefix="feud-hall-capacity-") as scratch:
        report = Path(scratch) / "measurement.json"
        # An existing database is an error. Only a successful creation authorizes cleanup.
        subprocess.run([bin_dir / "createdb", *common, "--template=template0", DATABASE],
                       check=True, env=env)
        try:
            memory = measure(args.days, report, env, args.mode)
            result = json.loads(report.read_text())
            if args.restore:
                result["archive_restore"] = restore_archive(bin_dir, common, env, Path(scratch))
            if fingerprint() != source:
                raise RuntimeError("Benchmark source changed during the run.")
        finally:
            subprocess.run([bin_dir / "dropdb", *common, DATABASE], check=True, env=env)

    result.update(memory=memory, head=revision, source_sha256=source,
                  machine={"os": platform.platform(), "cpu": platform.processor(),
                           "logical_cpus": os.cpu_count()})
    with output.open("x") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"Saved {output}. Dropped {DATABASE}.")


if __name__ == "__main__":
    main()
