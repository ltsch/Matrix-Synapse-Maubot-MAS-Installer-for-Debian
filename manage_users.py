#!/usr/bin/env python3
"""manage_users.py - user administration for a MAS-backed Synapse.

MAS (Matrix Authentication Service) owns accounts, passwords and sessions; it
provisions users into Synapse. Every change therefore goes through the MAS CLI
so the two stay consistent - never edit Synapse's users table directly.

Run as root. Listing reads both databases through local peer auth (no passwords).

  manage_users.py list
  manage_users.py register <localpart> [--admin]      # prompts for password
  manage_users.py lock <localpart>                    # block login, keep account
  manage_users.py unlock <localpart>
  manage_users.py deactivate <localpart>              # permanent (erases account in Synapse)
  manage_users.py reactivate <localpart>
  manage_users.py logout <localpart>                  # kill all sessions/devices
  manage_users.py promote <localpart> | demote <localpart>
  manage_users.py invite [--uses N] [--days D]        # registration token
"""
import argparse
import getpass
import os
import subprocess
import sys

MAS_BIN = "/opt/mas/mas"
MAS_CONFIG = "/opt/mas/config.yaml"


def mas(*args, check=True):
    """Run `mas manage ...` as the mas user; return combined output."""
    cmd = ["sudo", "-u", "mas", f"MAS_CONFIG={MAS_CONFIG}", MAS_BIN, "manage", *args]
    r = subprocess.run(cmd, cwd="/opt/mas", capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    if check and r.returncode != 0:
        sys.exit(f"mas {' '.join(args[:1])} failed:\n{out}")
    return out


def psql(db, query):
    r = subprocess.run(["sudo", "-u", "postgres", "psql", "-d", db, "-AtF", "\t", "-c", query],
                       cwd="/tmp", capture_output=True, text=True, check=True)
    return [line.split("\t") for line in r.stdout.splitlines() if line]


def list_users():
    mas_rows = psql("mas_db", "SELECT username, can_request_admin, locked_at IS NOT NULL, "
                              "deactivated_at IS NOT NULL, created_at::date FROM users ORDER BY username")
    syn = {r[0]: r for r in psql("synapse_db", "SELECT name, admin, deactivated, locked FROM users")}
    print(f"{'USER':<28} {'MAS-ADMIN':<9} {'LOCKED':<7} {'DEACT':<6} {'IN-SYNAPSE':<10} CREATED")
    for name, admin, locked, deact, created in mas_rows:
        s = next((v for k, v in syn.items() if k.startswith(f"@{name}:")), None)
        insyn = "no!" if s is None else "yes"
        yn = lambda b: "yes" if b in ("t", "1", "true") else "-"
        print(f"{name:<28} {yn(admin):<9} {yn(locked):<7} {yn(deact):<6} {insyn:<10} {created}")
    missing = [n for n, *_ in mas_rows if not any(k.startswith(f"@{n}:") for k in syn)]
    if missing:
        print(f"\nWARNING: in MAS but not Synapse (provisioning failed?): {', '.join(missing)}")


def main():
    if os.geteuid() != 0:
        sys.exit("run as root")
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    r = sub.add_parser("register"); r.add_argument("user"); r.add_argument("--admin", action="store_true")
    for c in ("lock", "unlock", "deactivate", "reactivate", "logout", "promote", "demote"):
        sub.add_parser(c).add_argument("user")
    i = sub.add_parser("invite"); i.add_argument("--uses", type=int, default=1); i.add_argument("--days", type=int, default=7)
    a = p.parse_args()

    user = getattr(a, "user", "").lstrip("@").split(":")[0]  # accept @user:server or localpart
    if a.cmd == "list":
        list_users()
    elif a.cmd == "register":
        pw = getpass.getpass(f"Password for {user}: ")
        args = ["register-user", user, "--password", pw, "--yes"] + (["--admin"] if a.admin else [])
        print(mas(*args))
    elif a.cmd == "lock":
        print(mas("lock-user", user))
    elif a.cmd == "unlock":
        print(mas("unlock-user", user))
    elif a.cmd == "deactivate":
        if input(f"Permanently deactivate {user}? type the username to confirm: ") != user:
            sys.exit("aborted")
        print(mas("lock-user", user, "--deactivate"))
    elif a.cmd == "reactivate":
        print(mas("unlock-user", user, "--reactivate"))
    elif a.cmd == "logout":
        print(mas("kill-sessions", user))
    elif a.cmd == "promote":
        print(mas("promote-admin", user))
    elif a.cmd == "demote":
        print(mas("demote-admin", user))
    elif a.cmd == "invite":
        print(mas("issue-user-registration-token", "--usage-limit", str(a.uses),
                  "--expires-in", str(a.days * 86400)))


if __name__ == "__main__":
    main()
