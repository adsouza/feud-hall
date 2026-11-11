"""Measure one real HTTP peak against a disposable local PostgreSQL hall."""

import argparse
import hashlib
import json
import platform
import os
from pathlib import Path
import subprocess
import time

from capacity_bench import SERVER, RSS_LIMIT_KIB, fingerprint, postgres_cli, rss_kib


def source_fingerprint():
    digest = hashlib.sha256(fingerprint().encode())
    for name in ("peak_sessions.py", "peak_sessions.exs"):
        digest.update((SERVER / "scripts" / name).read_bytes())
    return digest.hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--scenario", choices=("owners", "expanded"), default="owners")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or not output.parent.is_dir():
        parser.error("Output must be a new file in an existing directory.")

    source = source_fingerprint()
    postgres = postgres_cli()
    database = f"feud_hall_peak_{int(time.time())}_{os.getpid()}"
    env = dict(os.environ, PGHOST="localhost", PGPORT="5432", MIX_ENV="dev",
               FEUD_HALL_SERVE="0", FEUD_HALL_PEAK_DATABASE=database,
               FEUD_HALL_PEAK_REVISION=subprocess.check_output(
                   ["git", "rev-parse", "HEAD"], text=True, cwd=SERVER).strip())
    env.pop("DATABASE_URL", None)
    connection = ["--host=localhost", "--port=5432", "--maintenance-db=postgres", "--no-password"]
    subprocess.run([postgres / "createdb", *connection, "--template=template0", database],
                   check=True, env=env)
    peak = 0
    try:
        command = ["mix", "run", "--no-start", "scripts/peak_sessions.exs", str(output), args.scenario]
        with subprocess.Popen(command, cwd=SERVER, env=env) as probe:
            while probe.poll() is None:
                peak = max(peak, sum(rss_kib().values()))
                if peak > RSS_LIMIT_KIB:
                    probe.terminate()
                    raise RuntimeError("Local qualification exceeded the combined RSS limit.")
                time.sleep(0.5)
            if probe.returncode:
                raise subprocess.CalledProcessError(probe.returncode, command)
        if source_fingerprint() != source:
            raise RuntimeError("Qualification source changed during the run.")
        report = json.loads(output.read_text())
        report.update(source_sha256=source, peak_kib=peak, machine=platform.platform())
        output.write_text(json.dumps(report, indent=2) + "\n")
    finally:
        subprocess.run([postgres / "dropdb", *connection, database], check=True, env=env)


if __name__ == "__main__":
    main()
