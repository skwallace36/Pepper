#!/usr/bin/env python3
"""Create a new GitHub machine user agent for Pepper.

Usage (run in a separate terminal for interactive prompts):
    python3 scripts/create-agent.py 4
    python3 scripts/create-agent.py 4 --password 'MyPass123!'
    python3 scripts/create-agent.py 4 --skip-signup
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright


ENV_FILE = Path(__file__).resolve().parent.parent / ".env"

# Load defaults from .env
_env = {}
if ENV_FILE.exists():
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            _env[k.strip()] = v.strip()

DOMAIN = "stuartsagents.com"
DEFAULT_PASSWORD = _env.get("AGENT1_GITHUB_PASSWORD", "")
DEFAULT_REPO = "skwallace36/Pepper-private"


def github_signup(page, email: str, password: str, username: str):
    """Walk through the GitHub signup flow."""
    page.goto("https://github.com/signup")
    page.wait_for_load_state("networkidle")
    time.sleep(2)

    url = page.url

    # If redirected to homepage (not logged in), use the homepage signup form
    if "/signup" not in url:
        page.get_by_placeholder("you@domain.com").first.fill(email)
        page.get_by_role("button", name="Sign up for GitHub").first.click()
        page.wait_for_load_state("networkidle")
        time.sleep(2)

    # Step through the signup form — try each field with fallbacks
    # Email
    for selector in ["input#email", "input[name='email']", "input[type='email']"]:
        el = page.locator(selector)
        if el.count() > 0 and not el.input_value():
            el.fill(email)
            page.locator("button:has-text('Continue')").click()
            time.sleep(1)
            break

    # Password
    for selector in ["input#password", "input[name='password']", "input[type='password']"]:
        el = page.locator(selector)
        if el.count() > 0:
            el.first.fill(password)
            page.locator("button:has-text('Continue')").click()
            time.sleep(1)
            break

    # Username
    for selector in ["input#login", "input#username", "input[name='login']", "input[name='username']"]:
        el = page.locator(selector)
        if el.count() > 0:
            el.first.fill(username)
            page.locator("button:has-text('Continue')").click()
            time.sleep(1)
            break

    # Email preferences (try to uncheck)
    try:
        page.locator("input[type='checkbox']").first.uncheck(timeout=3000)
    except Exception:
        pass
    try:
        page.locator("button:has-text('Continue')").click(timeout=3000)
    except Exception:
        pass

    # Puzzle / captcha
    print("\n>>> If there's a puzzle or captcha, solve it in the browser now.")
    print(">>> When you see the email verification screen, press Enter...")
    input()

    # Email verification code
    print(f"\n>>> Check your Gmail for the verification code sent to {email}")
    code = input(">>> Enter the code: ").strip()

    # Try filling OTP
    filled = False
    for selector in ["input[name='otp']", "input#otp", "input[autocomplete='one-time-code']"]:
        otp = page.locator(selector)
        if otp.count() > 0:
            otp.first.fill(code)
            filled = True
            break

    if not filled:
        # Try typing into focused element
        page.keyboard.type(code)

    # Submit
    for btn_text in ["Verify", "Submit", "Continue"]:
        try:
            page.locator(f"button:has-text('{btn_text}')").click(timeout=3000)
            break
        except Exception:
            pass

    page.wait_for_load_state("networkidle")
    time.sleep(2)

    # Skip personalization if prompted
    try:
        skip = page.get_by_role("link", name="Skip")
        if skip.is_visible(timeout=3000):
            skip.click()
    except Exception:
        pass

    print(f">>> Signup complete for {username}")


def github_login(page, email: str, password: str):
    """Log into an existing GitHub account."""
    page.goto("https://github.com/login")
    page.wait_for_load_state("networkidle")
    page.get_by_role("textbox", name="Username or email address").fill(email)
    page.get_by_role("textbox", name="Password").fill(password)
    page.get_by_role("button", name="Sign in").click()
    page.wait_for_load_state("networkidle")
    time.sleep(2)


def create_classic_pat(page, token_name: str = "pepper") -> str:
    """Navigate to settings and create a classic PAT with repo scope."""
    page.goto("https://github.com/settings/tokens/new")
    page.wait_for_load_state("networkidle")
    time.sleep(1)

    # Fill token name
    page.get_by_role("textbox", name="Note").fill(token_name)

    # Set expiration to "No expiration"
    # Click the expiration dropdown button
    exp_btn = page.locator("button:has-text('days')")
    if exp_btn.count() > 0:
        exp_btn.first.click()
        time.sleep(0.5)
        page.get_by_role("menuitemradio", name="No expiration").click()
        time.sleep(0.5)

    # Check repo scope
    page.get_by_role("checkbox", name="repo Full control of private").check()

    # Generate
    page.get_by_role("button", name="Generate token").click()
    page.wait_for_load_state("networkidle")
    time.sleep(1)

    # Extract the token
    token_el = page.locator("code#new-oauth-token, [id='new-oauth-token']")
    if token_el.count() > 0:
        token = token_el.inner_text().strip()
    else:
        # Fallback — look for code element near the copy button
        token_el = page.locator("code").first
        if token_el.count() > 0:
            text = token_el.inner_text().strip()
            if text.startswith("ghp_"):
                token = text
            else:
                print("\n>>> Could not auto-extract the token.")
                token = input(">>> Copy the token from the browser and paste it here: ").strip()
        else:
            print("\n>>> Could not auto-extract the token.")
            token = input(">>> Copy the token from the browser and paste it here: ").strip()

    return token


def invite_collaborator(repo: str, username: str):
    """Invite the machine user as a collaborator via gh CLI."""
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/collaborators/{username}", "-X", "PUT", "-f", "permission=write"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"Warning: invite may have failed: {result.stderr}")
    else:
        print(f">>> Invited {username} as collaborator on {repo}")


def accept_invite_via_api(pat: str, repo: str):
    """Accept the collaborator invite using the agent's PAT."""
    import json
    import urllib.request

    req = urllib.request.Request(
        "https://api.github.com/user/repository_invitations",
        headers={"Authorization": f"token {pat}", "Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(req) as resp:
        invites = json.loads(resp.read())

    for invite in invites:
        if invite["repository"]["full_name"] == repo:
            accept_req = urllib.request.Request(
                f"https://api.github.com/user/repository_invitations/{invite['id']}",
                method="PATCH",
                headers={"Authorization": f"token {pat}", "Accept": "application/vnd.github+json"},
            )
            urllib.request.urlopen(accept_req)
            print(f">>> Accepted invite for {repo}")
            return

    print(">>> No pending invite found (may already be accepted)")


def test_access(username: str, pat: str, repo: str) -> bool:
    """Verify the PAT works against the repo."""
    result = subprocess.run(
        ["git", "ls-remote", f"https://{username}:{pat}@github.com/{repo}.git", "HEAD"],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        print(f">>> Access confirmed: {username} can reach {repo}")
        return True
    else:
        print(f">>> Access FAILED: {result.stderr.strip()}")
        return False


def append_to_env(n: int, username: str, email: str, password: str, pat: str):
    """Append agent credentials to .env."""
    block = f"""
# Machine user: agent-{n}
AGENT{n}_GITHUB_USERNAME={username}
AGENT{n}_GITHUB_EMAIL={email}
AGENT{n}_GITHUB_PASSWORD={password}
AGENT{n}_GITHUB_PAT={pat}
"""
    with open(ENV_FILE, "a") as f:
        f.write(block)
    print(f">>> Appended agent-{n} credentials to {ENV_FILE}")


def main():
    parser = argparse.ArgumentParser(description="Create a new GitHub machine user agent")
    parser.add_argument("number", type=int, help="Agent number (e.g., 4)")
    parser.add_argument("--password", default=DEFAULT_PASSWORD, help="Account password")
    parser.add_argument("--repo", default=DEFAULT_REPO, help="Repo to grant access to")
    parser.add_argument("--skip-signup", action="store_true", help="Skip signup (account already exists)")
    args = parser.parse_args()

    n = args.number
    username = f"stuartsagent{n}"
    email = f"agent-{n}@{DOMAIN}"
    password = args.password

    print(f"\n=== Creating agent-{n} ===")
    print(f"    Username: {username}")
    print(f"    Email:    {email}")
    print(f"    Repo:     {args.repo}\n")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)
        context = browser.new_context()
        page = context.new_page()

        if not args.skip_signup:
            github_signup(page, email, password, username)
        else:
            github_login(page, email, password)

        # Create PAT
        print("\n>>> Creating classic PAT...")
        pat = create_classic_pat(page, token_name="pepper")
        print(f">>> PAT: {pat[:10]}...")

        browser.close()

    # Invite as collaborator
    invite_collaborator(args.repo, username)

    # Accept invite via API
    accept_invite_via_api(pat, args.repo)

    # Test
    if test_access(username, pat, args.repo):
        append_to_env(n, username, email, password, pat)
        print(f"\n=== agent-{n} is ready! ===\n")
    else:
        print(f"\n=== Access failed — credentials NOT saved. Debug and retry. ===\n")
        print(f"PAT was: {pat}")
        sys.exit(1)


if __name__ == "__main__":
    main()
