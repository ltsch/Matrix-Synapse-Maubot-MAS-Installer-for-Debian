#!/usr/bin/env python3
import argparse
import subprocess
import sys
from datetime import datetime

# Database Config
DB_USER = "synapse_user"
DB_NAME = "synapse_db"
# PGPASSWORD environment variable should be set when running,
# or hardcoded for this helper
DB_PASS = "Dv421HlSc9scTgQxxCFFvlSHpcJOb8Eu"
DB_HOST = "127.0.0.1"

# MAS Config
MAS_BIN = "/opt/mas/mas"
MAS_CONFIG = "/opt/mas/config.yaml"


def run_sql(query, fetch=True):
    """Executes a SQL query. If fetch=True, uses COPY TO STDOUT for CSV output."""
    if fetch:
        # Use COPY for SELECTs to get clean CSV
        cmd = [
            "psql",
            "-h",
            DB_HOST,
            "-U",
            DB_USER,
            "-d",
            DB_NAME,
            "-c",
            f"COPY ({query}) TO STDOUT WITH CSV HEADER",
        ]
    else:
        # Direct execution for UPDATE/DELETE
        cmd = [
            "psql", "-h", DB_HOST, "-U", DB_USER, "-d", DB_NAME, "-c", query
        ]

    env = {"PGPASSWORD": DB_PASS, "PATH": "/usr/bin:/bin"}

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, env=env, check=True
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error executing SQL: {e.stderr}", file=sys.stderr)
        sys.exit(1)


def list_users():
    """Lists all users from Synapse DB."""
    query = (
        "SELECT name, admin, deactivated, creation_ts FROM users ORDER BY name ASC"
    )
    csv_output = run_sql(query)

    print(f"{'USERNAME':<40} {'ADMIN':<10} {'DEACTIVATED':<12} {'CREATED'}")
    print("-" * 80)

    # Parse CSV manually (simple enough for this output)
    for line in csv_output.strip().split("\n"):
        if not line or line.startswith("name,admin"):
            continue
        parts = line.split(",")
        if len(parts) >= 4:
            name = parts[0]
            admin = "Yes" if parts[1] == "1" else "No"
            deact = "Yes" if parts[2] == "1" else "No"
            try:
                # TS is usually seconds or milliseconds? Synapse uses seconds.
                ts = datetime.fromtimestamp(int(parts[3])).strftime("%Y-%m-%d")
            except Exception:
                ts = parts[3]

            print(f"{name:<40} {admin:<10} {deact:<12} {ts}")


def delete_user(username):
    """Deactivates user in Synapse and Locks in MAS."""
    print(f"[*] Deactivating user {username}...")

    # 1. Deactivate in Synapse DB
    deact_sql = (
        f"UPDATE users SET deactivated = 1, password_hash='' WHERE name = '{username}'"
    )
    run_sql(deact_sql, fetch=False)
    print("    - Marked deactivated in Synapse DB.")

    # 2. Lock in MAS (Prevent Login)
    # MAS username is usually the localpart, but let's try to match.
    # We'll assume input is full MXID or localpart.
    localpart = username.split(":")[0].replace("@", "")

    cmd = [MAS_BIN, "manage", "lock-user", localpart]
    env = {"MAS_CONFIG": MAS_CONFIG, "PATH": "/usr/bin:/bin"}

    print(f"    - Locking user '{localpart}' in MAS...")
    try:
        subprocess.run(cmd, env=env, check=False)  # Don't error if user not in MAS
    except Exception as e:
        print(f"    ! Warning: Failed to run MAS lock: {e}")

    print(f"[+] User {username} has been processed.")


def main():
    parser = argparse.ArgumentParser(
        description="Manage Matrix Users (Custom Script)"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # List command
    subparsers.add_parser("list", help="List all users")

    # Delete command
    del_parser = subparsers.add_parser("delete", help="Delete (Deactivate) a user")
    del_parser.add_argument(
        "username", help="Full MXID (e.g. @user:chat.minn.info)"
    )

    args = parser.parse_args()

    if args.command == "list":
        list_users()
    elif args.command == "delete":
        if not args.username.startswith("@"):
            print("Error: Please provide full MXID (e.g. @user:chat.minn.info)")
            sys.exit(1)
        delete_user(args.username)


if __name__ == "__main__":
    main()
