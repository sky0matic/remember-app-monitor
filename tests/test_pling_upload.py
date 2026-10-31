"""Tests for the local changes to the vendored KDE Store uploader (scripts/pling_upload.py)."""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
import pling_upload  # noqa: E402

RELEASE_PLEASE_CHANGELOG = """# Changelog

## [1.1.0](https://github.com/owner/remember-app-monitor/compare/v1.0.0...v1.1.0) (2026-11-02)


### Features

* pick apps from a searchable list

## [1.0.10](https://github.com/owner/remember-app-monitor/compare/v1.0.9...v1.0.10) (2026-11-01)

### Bug Fixes

* something

## 1.0.0 (2026-10-31)


### Features

* initial release
"""


class ReleaseNotesTest(unittest.TestCase):
    def test_release_please_heading_with_link(self):
        notes = pling_upload.parse_release_notes("1.1.0", RELEASE_PLEASE_CHANGELOG)
        self.assertEqual(notes.title, "1.1.0 (2026-11-02)")
        self.assertEqual(notes.text, "### Features\n\n* pick apps from a searchable list")

    def test_first_release_heading_without_link(self):
        notes = pling_upload.parse_release_notes("1.0.0", RELEASE_PLEASE_CHANGELOG)
        self.assertEqual(notes.title, "1.0.0 (2026-10-31)")
        self.assertEqual(notes.text, "### Features\n\n* initial release")

    def test_version_prefix_does_not_match_longer_version(self):
        with self.assertRaises(pling_upload.PlingUploaderError):
            pling_upload.parse_release_notes("1.0.1", RELEASE_PLEASE_CHANGELOG)

    def test_missing_version(self):
        with self.assertRaises(pling_upload.PlingUploaderError):
            pling_upload.parse_release_notes("9.9.9", RELEASE_PLEASE_CHANGELOG)


class _FakeResponse:
    def __init__(self, text, url):
        self.text = text
        self.url = url
        self.status_code = 200


class _FakeSession:
    """Serves a login page and records every request, so we can check where credentials go."""

    def __init__(self, login_html):
        self.login_html = login_html
        self.requests = []
        self.headers = {}
        self.cookies = None

    def request(self, method, url, *, timeout, **kwargs):
        self.requests.append((method, url, kwargs))
        return _FakeResponse(self.login_html, url)


def _login_page(action):
    return f"""<form action="{action}" method="post">
        <input type="hidden" name="csrf" value="x"><input type="hidden" name="redirect_url" value="">
        <input type="hidden" name="twit" value=""><input name="email"><input name="password" type="password">
    </form>"""


def _config():
    return pling_upload.RuntimeConfig(
        project_id="123", base_url="https://www.opendesktop.org", username="me@example.com",
        password="secret", timeout=5, max_retries=0, dry_run=True, artifact_paths=[],
    )


class CredentialsHostTest(unittest.TestCase):
    def test_refuses_login_form_on_other_host(self):
        session = _FakeSession(_login_page("https://evil.example.com/login"))
        with self.assertRaises(pling_upload.PlingUploaderError):
            pling_upload.discover_edit_context(session, _config())
        self.assertFalse(any("secret" in str(kwargs) for _, _, kwargs in session.requests))

    def test_relative_login_action_is_allowed(self):
        session = _FakeSession(_login_page("/login/"))
        # the fake edit page is the login page again, so it fails later, after posting the login
        with self.assertRaises(pling_upload.PlingUploaderError):
            pling_upload.discover_edit_context(session, _config())
        method, url, kwargs = session.requests[1]
        self.assertEqual((method, url), ("POST", "https://www.opendesktop.org/login/"))
        self.assertEqual(kwargs["data"]["password"], "secret")


if __name__ == "__main__":
    unittest.main()
