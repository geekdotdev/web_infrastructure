#!/usr/bin/env python3
# MVP deployment pipeline for one environment.
#
# This used to be a bash script; it was rewritten in Python after hitting
# real, wasted-time bugs specific to shell — macOS's frozen bash 3.2 choking
# on empty-array expansion under `set -u`, and JSON handling done via
# `python3 -c '...'` one-liners embedded in bash heredocs (fragile quoting).
# Same logic, no shell footguns.
#
# Usage: deployment/deploy.py <env> [--profile NAME] [-- extra cdk args...]
#   e.g. deployment/deploy.py dev
#        deployment/deploy.py prod --profile prod-admin
#        deployment/deploy.py qa --profile qa -- --require-approval never
#
# Phases run in order (preflight, synth, deploy, push_artifacts,
# post_deploy), each a plain function so future stages slot in easily.
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUTS_DIR = REPO_ROOT / "deployment" / "outputs"


def log(env_label: str, msg: str) -> None:
    print(f">>> [{env_label}] {msg}")


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def load_environments() -> dict:
    path = REPO_ROOT / "environments.json"
    if not path.exists():
        fail("environments.json missing — copy environments.json.example and fill it in")
    return json.loads(path.read_text())


def resolve_profile(env_label: str, cli_profile: str | None, environments: dict) -> str:
    """
    Strict profile resolution: a profile MUST come from --profile or the
    env's "profile" attribute in environments.json. No fallback to the
    default credential chain — wrong-account accidents are the failure mode
    this pipeline exists to prevent.
    """
    profile = cli_profile or environments.get(env_label, {}).get("profile", "")
    if not profile:
        fail(
            f"no AWS profile for env '{env_label}'. Pass --profile, or add "
            f"\"profile\" to the '{env_label}' entry in environments.json. "
            f"Refusing to fall back to the default credential chain."
        )
    else:
        log(env_label, f"using profile: {profile}" + ("" if cli_profile else " (from environments.json)"))

    result = subprocess.run(
        ["aws", "configure", "list-profiles"], capture_output=True, text=True
    )
    known = result.stdout.splitlines()
    if profile not in known:
        fail(f"profile '{profile}' not found (checked ~/.aws/config and ~/.aws/credentials)")
    return profile


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    kwargs.setdefault("cwd", REPO_ROOT)
    return subprocess.run(cmd, check=True, **kwargs)


# --- Phase 1: preflight ------------------------------------------------------
def preflight(env_label: str, environments: dict) -> None:
    log(env_label, "preflight")

    if env_label not in environments:
        fail(f"env '{env_label}' not found in environments.json")

    key_path = REPO_ROOT / "keys" / f"{env_label}-public.pem"
    if not key_path.exists():
        fail(f"{key_path.relative_to(REPO_ROOT)} missing — see README 'CloudFront signing keys'")

    if not (REPO_ROOT / "node_modules").is_dir():
        log(env_label, "installing dependencies")
        run(["npm", "install", "--no-audit", "--no-fund"])

    log(env_label, "type-check")
    run(["npx", "tsc", "--noEmit"])


# --- Phase 2: synth ----------------------------------------------------------
def synth(env_label: str, profile: str) -> None:
    log(env_label, "synth")
    run(["npx", "cdk", "synth", "--quiet", "-c", f"env={env_label}", "--profile", profile])


# --- Phase 3: deploy ----------------------------------------------------------
def deploy(env_label: str, profile: str, extra_args: list[str]) -> Path:
    log(env_label, f"deploy GhostLightsailStack-{env_label}")
    OUTPUTS_DIR.mkdir(parents=True, exist_ok=True)
    outputs_file = OUTPUTS_DIR / f"{env_label}.json"
    run(
        ["npx", "cdk", "deploy", "-c", f"env={env_label}",
         "--outputs-file", str(outputs_file), "--profile", profile, *extra_args]
    )
    now_local = datetime.now().astimezone()
    now_utc = datetime.now(timezone.utc)
    log(env_label, f"stack created/updated at {now_local:%Y-%m-%d %H:%M:%S %Z} ({now_utc:%H:%M:%S} UTC)")
    return outputs_file


# --- Phase 4: push private artifacts -----------------------------------------
# Config pipeline stage 2 (source -> PUSH -> pull -> consume): stage required
# artifacts from local sources and upload them to the deployment bucket with
# an ephemeral Lightsail bucket access key (created, used, deleted in a
# finally-block so cleanup runs even if the push itself fails). The
# instance's first boot blocks until these files land.
def push_artifacts(env_label: str, profile: str, environments: dict) -> None:
    log(env_label, "push private artifacts")
    bucket = f"geek-dot-dev-deployment-resources-{env_label}"
    region = environments.get(env_label, {}).get("region", "us-east-1")

    with tempfile.TemporaryDirectory() as stage_dir_str:
        stage_dir = Path(stage_dir_str)

        pw = environments.get(env_label, {}).get("mysqlRootPassword")
        if not pw:
            fail(f"mysqlRootPassword missing for env '{env_label}' in environments.json")
        mysql_env = stage_dir / "mysql.env"
        mysql_env.write_text(f"MYSQL_ROOT_PASSWORD={pw}\n")
        mysql_env.chmod(0o600)

        # Optional: SES SMTP credentials. Not required — envs without SES set
        # up yet simply keep Ghost's Direct mail transport (see user-data.sh).
        env_cfg = environments.get(env_label, {})
        ses_host = env_cfg.get("sesSmtpHost")
        ses_user = env_cfg.get("sesSmtpUsername")
        ses_pass = env_cfg.get("sesSmtpPassword")
        if ses_host and ses_user and ses_pass:
            mail_env = stage_dir / "mail.env"
            mail_env.write_text(
                f"SES_SMTP_HOST={ses_host}\n"
                f"SES_SMTP_USERNAME={ses_user}\n"
                f"SES_SMTP_PASSWORD={ses_pass}\n"
            )
            mail_env.chmod(0o600)
            log(env_label, "including SES SMTP credentials (mail.env)")
        else:
            log(env_label, "no SES SMTP credentials in environments.json — mail stays on Direct transport")

        # Optional extra private artifacts: private-config/<env>/ (gitignored).
        extra_dir = REPO_ROOT / "private-config" / env_label
        if extra_dir.is_dir():
            shutil.copytree(extra_dir, stage_dir, dirs_exist_ok=True)

        log(env_label, f"minting ephemeral access key for {bucket}")
        key_result = run(
            ["aws", "lightsail", "create-bucket-access-key", "--bucket-name", bucket,
             "--region", region, "--profile", profile, "--output", "json"],
            capture_output=True, text=True,
        )
        key_data = json.loads(key_result.stdout)["accessKey"]
        akid, secret = key_data["accessKeyId"], key_data["secretAccessKey"]

        pushed = False
        try:
            sync_env = {**os.environ, "AWS_ACCESS_KEY_ID": akid,
                        "AWS_SECRET_ACCESS_KEY": secret, "AWS_SESSION_TOKEN": ""}
            for attempt in range(6):  # new keys can take a few seconds to propagate
                result = subprocess.run(
                    ["aws", "s3", "sync", str(stage_dir), f"s3://{bucket}/", "--region", region],
                    env=sync_env,
                )
                if result.returncode == 0:
                    pushed = True
                    break
                time.sleep(5)
        finally:
            cleanup = subprocess.run(
                ["aws", "lightsail", "delete-bucket-access-key", "--bucket-name", bucket,
                 "--access-key-id", akid, "--region", region, "--profile", profile]
            )
            if cleanup.returncode != 0:
                log(env_label, f"WARNING: failed to delete ephemeral access key {akid} — delete it manually")

    if not pushed:
        fail(f"artifact push to {bucket} failed")
    log(env_label, f"artifacts pushed to {bucket}")


# --- Phase 5: post-deploy ----------------------------------------------------
# Future pipeline stages land here: verify DNS/TLS, smoke-test the journal.
def post_deploy(env_label: str, outputs_file: Path) -> None:
    log(env_label, "post-deploy")
    if outputs_file.exists():
        log(env_label, f"stack outputs written to {outputs_file.relative_to(REPO_ROOT)}:")
        print(json.dumps(json.loads(outputs_file.read_text()), indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Deploy one environment's Ghost Lightsail stack.",
        usage="deployment/deploy.py <env> [--profile NAME] [-- extra cdk args...]",
    )
    parser.add_argument("env", help="Environment label (dev, qa, prod, ...)")
    parser.add_argument("--profile", help="AWS profile (falls back to environments.json)")
    parser.add_argument("cdk_args", nargs="*", help="Extra args passed through to `cdk deploy` (put after --)")
    args = parser.parse_args()

    env_label = args.env
    environments = load_environments()
    profile = resolve_profile(env_label, args.profile, environments)

    preflight(env_label, environments)
    synth(env_label, profile)
    outputs_file = deploy(env_label, profile, args.cdk_args)
    push_artifacts(env_label, profile, environments)
    post_deploy(env_label, outputs_file)
    log(env_label, "done")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        fail(f"command failed ({' '.join(e.cmd)}): exit {e.returncode}")
    except FileNotFoundError as e:
        fail(f"required command not found: {e.filename} (is it installed and on PATH?)")
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
