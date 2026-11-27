"""MAS invite-token generator (mas-invite.service).

Tiny Flask app that calls `mas manage issue-user-registration-token` and shows a
registration link. Listens on 127.0.0.1:8081; nginx exposes it at /register and
the edge proxy (Caddy) must put authentication in front of it.

NOTE: runs on Flask's built-in development server (see docs/ARCHITECTURE.md).
"""
import os
import re
import subprocess
import sys

from flask import Flask, render_template_string, request

# Public base URL of MAS, e.g. https://auth.chat.example.com
MAS_PUBLIC_BASE = os.environ.get("MAS_PUBLIC_BASE", "https://auth.chat.example.com").rstrip("/")
MAS_BIN = os.environ.get("MAS_BIN", "/opt/mas/mas")
MAS_CONFIG = os.environ.get("MAS_CONFIG", "/opt/mas/config.yaml")

app = Flask(__name__)

HTML = """
<!DOCTYPE html>
<html>
<head>
    <title>Matrix Invite Generator</title>
    <style>
        body { font-family: sans-serif; max-width: 600px; margin: 40px auto; padding: 20px; text-align: center; }
        button { padding: 15px 30px; font-size: 18px; cursor: pointer; background: #008080; color: white; border: none; border-radius: 5px; }
        button:hover { background: #006666; }
        .code { margin-top: 20px; padding: 15px; background: #f0f0f0; border-radius: 5px; word-break: break-all; }
        .token { font-family: monospace; font-size: 22px; letter-spacing: 1px; user-select: all; }
        ol { text-align: left; }
    </style>
</head>
<body>
    <h1>Generate Matrix Invite</h1>
    <form method="POST">
        <button type="submit">Generate Invite Token</button>
    </form>
    {% if token %}
        <div class="code">
            <strong>Invite token</strong> <small>(valid for 5 sign-ups, expires in 30 days)</small><br>
            <span class="token">{{ token }}</span>
            <ol>
                <li>Open <a href="{{ base }}/register">{{ base }}/register</a></li>
                <li>Choose <em>Continue with Google</em> or create a username and password</li>
                <li>When asked for a <strong>registration token</strong>, paste the token above</li>
                <li>Then sign in with Element (web, desktop or Element X) using that account</li>
            </ol>
        </div>
    {% endif %}
    {% if error %}
        <div style="color: red; margin-top: 20px;">{{ error }}</div>
    {% endif %}
</body>
</html>
"""


@app.route("/", methods=["GET", "POST"])
def index():
    token = None
    error = None
    if request.method == "POST":
        try:
            # Run MAS CLI to generate token
            # Note: MAS outputs the token to stderr logs, not stdout
            result = subprocess.run(
                [
                    MAS_BIN,
                    "-c",
                    MAS_CONFIG,
                    "manage",
                    "issue-user-registration-token",
                    "--usage-limit", "5",
                    "--expires-in", "2592000", # 30 Days
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            
            # Combine stdout and stderr for searching
            output = result.stdout + result.stderr

            # Look for the token in the log message: "Created user registration token: <TOKEN>"
            match = re.search(r"Created user registration token: (\w+)", output)
            if match:
                token = match.group(1)
            else:
                error = "Could not find token in MAS output"
                print(f"ERROR: No token match found in output", file=sys.stderr)

        except subprocess.CalledProcessError as e:
            error = f"Error generating token: {e.stderr}"
            print(f"ERROR: CLI Error: {e.stderr}", file=sys.stderr)
        except Exception as e:
            error = str(e)
            print(f"ERROR: Exception: {e}", file=sys.stderr)

    return render_template_string(HTML, token=token, error=error, base=MAS_PUBLIC_BASE)


if __name__ == "__main__":
    # Run heavily limited as it's behind Nginx/Caddy
    app.run(host="127.0.0.1", port=8081)
