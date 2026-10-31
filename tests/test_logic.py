"""Unit tests for package/contents/code/logic.js.

The logic runs in Qt's QJSEngine (via PySide6), the same JavaScript engine KWin uses.
Run with: python3 -m unittest discover -s tests
"""

import json
import pathlib
import unittest

from PySide6.QtCore import QCoreApplication
from PySide6.QtQml import QJSEngine

LOGIC = pathlib.Path(__file__).resolve().parent.parent / "package" / "contents" / "code" / "logic.js"

ASUS = {"manufacturer": "ASUSTek COMPUTER INC", "model": "VG27A", "serialNumber": "M2LMQS140612", "name": "HDMI-A-1"}
ASUS_OTHER_DESK = {**ASUS, "serialNumber": "OTHERSERIAL1", "name": "DP-2"}
SAMSUNG = {"manufacturer": "Samsung Electric Company", "model": "LC34G55T", "serialNumber": "HNTX302373", "name": "DP-1"}
NO_SERIAL = {"manufacturer": "Generic", "model": "Panel", "serialNumber": "", "name": "eDP-1"}

ASUS_ID = "ASUSTek COMPUTER INC|VG27A|M2LMQS140612"
SAMSUNG_ID = "Samsung Electric Company|LC34G55T|HNTX302373"

_app = QCoreApplication.instance() or QCoreApplication([])


class LogicTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = LOGIC.read_text()
        # ".pragma library" is QML-only syntax
        source = "\n".join(line for line in source.splitlines() if line.strip() != ".pragma library")
        cls.engine = QJSEngine()
        result = cls.engine.evaluate(source, str(LOGIC))
        if result.isError():
            raise RuntimeError(result.toString())

    def call(self, fn, *args):
        """Calls a logic.js function with JSON-serializable args and returns its JSON-decoded result."""
        encoded = ", ".join(json.dumps(a) for a in args)
        result = self.engine.evaluate(f"JSON.stringify({fn}({encoded}))")
        if result.isError():
            raise AssertionError(f"{fn} threw: {result.toString()}")
        text = result.toString()
        return None if text == "undefined" else json.loads(text)


class SectionsTest(LogicTest):
    def test_section_ids_are_unique(self):
        ids = self.call("(() => SECTIONS.map(s => s.id))")
        self.assertEqual(len(ids), len(set(ids)))

    def test_default_section_exists(self):
        self.assertIsNotNone(self.call("sectionById", self.call("(() => DEFAULT_SECTION)")))

    def test_section_index(self):
        self.assertEqual(self.call("sectionIndex", "left"), 0)
        self.assertEqual(self.call("sectionIndex", "nope"), -1)


class AppsConfigTest(LogicTest):
    def test_normalize_trims_lowercases_and_dedupes(self):
        apps = self.call("normalizeApps", [
            {"app": "  Discord ", "section": "LEFT"},
            {"app": "discord", "section": "right"},
            {"app": "", "section": "left"},
            {"app": "org.kde.kcalc", "section": "bogus"},
        ])
        self.assertEqual(apps, [
            {"app": "discord", "section": "left"},
            {"app": "org.kde.kcalc", "section": "keep"},
        ])

    def test_parse_and_serialize_round_trip(self):
        apps = [{"app": "discord", "section": "left"}, {"app": "firefox", "section": "maximized"}]
        self.assertEqual(self.call("parseApps", self.call("serializeApps", apps)), apps)

    def test_parse_invalid_json_gives_empty_list(self):
        self.assertEqual(self.call("parseApps", "{not json"), [])
        self.assertEqual(self.call("parseApps", '{"app": "x"}'), [])
        self.assertEqual(self.call("parseApps", ""), [])

    def test_parse_legacy_text(self):
        text = "# comment\ndiscord = left\n\norg.kde.kcalc=bottom-right\nfirefox\n"
        self.assertEqual(self.call("parseLegacyApps", text), [
            {"app": "discord", "section": "left"},
            {"app": "org.kde.kcalc", "section": "bottom-right"},
            {"app": "firefox", "section": "keep"},
        ])

    def test_find_app_checks_every_window_name_case_insensitively(self):
        apps = [{"app": "discord", "section": "left"}]
        self.assertEqual(self.call("findApp", apps, ["", "Discord", None]), apps[0])
        self.assertEqual(self.call("findApp", apps, ["X", "x", "x"]), None)


class MonitorTest(LogicTest):
    def test_monitor_id_includes_serial(self):
        self.assertEqual(self.call("monitorId", ASUS), ASUS_ID)

    def test_same_model_with_different_serial_does_not_match(self):
        self.assertEqual(self.call("findOutput", [ASUS_OTHER_DESK, SAMSUNG], ASUS_ID), None)
        self.assertEqual(self.call("findOutput", [ASUS_OTHER_DESK, ASUS], ASUS_ID)["name"], "HDMI-A-1")

    def test_legacy_id_without_serial_matches_by_model(self):
        self.assertEqual(self.call("findOutput", [SAMSUNG, ASUS], "ASUSTek COMPUTER INC|VG27A")["name"], "HDMI-A-1")

    def test_monitor_without_serial(self):
        no_serial_id = self.call("monitorId", NO_SERIAL)
        self.assertEqual(self.call("findOutput", [SAMSUNG, NO_SERIAL], no_serial_id)["name"], "eDP-1")

    def test_empty_id_matches_nothing(self):
        self.assertEqual(self.call("findOutput", [NO_SERIAL, {"manufacturer": "", "model": "", "serialNumber": ""}], ""), None)

    def test_monitor_label(self):
        self.assertEqual(self.call("monitorLabel", ASUS_ID), "VG27A (ASUSTek COMPUTER INC)")
        self.assertEqual(self.call("monitorLabel", "|Panel|"), "Panel")
        self.assertEqual(self.call("monitorLabel", ""), "")

    def test_monitor_details(self):
        self.assertEqual(self.call("monitorDetails", ASUS_ID), "VG27A (ASUSTek COMPUTER INC), S/N M2LMQS140612")
        self.assertEqual(self.call("monitorDetails", "ASUSTek COMPUTER INC|VG27A"), "VG27A (ASUSTek COMPUTER INC)")


class PlacementTest(LogicTest):
    def test_remembered_monitor_connected(self):
        plan = self.call("planPlacement", ASUS_ID, [ASUS, SAMSUNG], [SAMSUNG, ASUS])
        self.assertEqual(plan["kind"], "section")
        self.assertEqual(plan["output"]["name"], "HDMI-A-1")

    def test_remembered_monitor_missing_goes_to_main(self):
        plan = self.call("planPlacement", ASUS_ID, [SAMSUNG, ASUS_OTHER_DESK], [SAMSUNG, ASUS_OTHER_DESK])
        self.assertEqual(plan["kind"], "main")
        self.assertEqual(plan["output"]["name"], "DP-1")

    def test_nothing_remembered_goes_to_main(self):
        plan = self.call("planPlacement", "", [ASUS, SAMSUNG], [SAMSUNG, ASUS])
        self.assertEqual(plan, {"kind": "main", "output": SAMSUNG})

    def test_no_screens(self):
        self.assertEqual(self.call("planPlacement", ASUS_ID, [], []), {"kind": "main", "output": None})


class GeometryTest(LogicTest):
    # usable area of the second monitor: 2560x1440 at 338,0 with a 40px bottom panel
    AREA = {"x": 338, "y": 0, "width": 2560, "height": 1400}
    CURRENT = {"x": 0, "y": 0, "width": 800, "height": 600}

    def geometry(self, section, current=None):
        return self.call("sectionGeometry", section, self.AREA, current or self.CURRENT)

    def test_halves(self):
        self.assertEqual(self.geometry("left"), {"x": 338, "y": 0, "width": 1280, "height": 1400})
        self.assertEqual(self.geometry("right"), {"x": 1618, "y": 0, "width": 1280, "height": 1400})
        self.assertEqual(self.geometry("bottom"), {"x": 338, "y": 700, "width": 2560, "height": 700})

    def test_quarter(self):
        self.assertEqual(self.geometry("bottom-right"), {"x": 1618, "y": 700, "width": 1280, "height": 700})

    def test_thirds_are_rounded_and_cover_the_width(self):
        thirds = [self.geometry(s) for s in ("left-third", "center-third", "right-third")]
        self.assertEqual([t["x"] for t in thirds], [338, 1191, 2045])
        self.assertTrue(all(t["width"] == 853 for t in thirds))

    def test_center_keeps_size(self):
        self.assertEqual(self.geometry("center"), {"x": 1218, "y": 400, "width": 800, "height": 600})

    def test_center_shrinks_oversized_windows_to_the_area(self):
        g = self.geometry("center", {"x": 0, "y": 0, "width": 4000, "height": 2000})
        self.assertEqual(g, {"x": 338, "y": 0, "width": 2560, "height": 1400})

    def test_sections_without_geometry(self):
        self.assertIsNone(self.geometry("keep"))
        self.assertIsNone(self.geometry("maximized"))
        self.assertIsNone(self.geometry("bogus"))


class TimingTest(LogicTest):
    GRACE = 4000
    SETTLE = 3000

    def test_undo_maximize_only_during_grace(self):
        self.assertTrue(self.call("shouldUndoMaximize", "left", 1000, 3, self.GRACE))
        self.assertFalse(self.call("shouldUndoMaximize", "left", 5000, 3, self.GRACE))

    def test_no_undo_when_not_maximized(self):
        self.assertFalse(self.call("shouldUndoMaximize", "left", 1000, 0, self.GRACE))

    def test_no_undo_for_maximized_or_keep(self):
        self.assertFalse(self.call("shouldUndoMaximize", "maximized", 1000, 3, self.GRACE))
        self.assertFalse(self.call("shouldUndoMaximize", "keep", 1000, 3, self.GRACE))

    def test_remember_only_user_moves(self):
        self.assertTrue(self.call("shouldRemember", 10000, 10000, self.GRACE, self.SETTLE))
        self.assertFalse(self.call("shouldRemember", 1000, 10000, self.GRACE, self.SETTLE))  # our own placement
        self.assertFalse(self.call("shouldRemember", 10000, 500, self.GRACE, self.SETTLE))   # monitor unplugged


class SuggestionsTest(LogicTest):
    WINDOWS = [{"app": "discord", "label": "Friends - Discord"}, {"app": "Helium", "label": "Helium"}]
    DESKTOP = ["discord", "org.kde.kcalc", "org.kde.konsole"]

    def test_open_windows_first_and_deduplicated(self):
        s = self.call("buildSuggestions", self.WINDOWS, self.DESKTOP)
        self.assertEqual([x["app"] for x in s], ["discord", "helium", "org.kde.kcalc", "org.kde.konsole"])
        self.assertEqual(s[0], {"app": "discord", "label": "Friends - Discord", "source": "open"})
        self.assertEqual(s[2]["source"], "installed")

    def test_filter_matches_app_id_or_label(self):
        s = self.call("buildSuggestions", self.WINDOWS, self.DESKTOP)
        self.assertEqual([x["app"] for x in self.call("filterSuggestions", s, "KDE")], ["org.kde.kcalc", "org.kde.konsole"])
        self.assertEqual([x["app"] for x in self.call("filterSuggestions", s, "friends")], ["discord"])

    def test_empty_query_returns_all_up_to_limit(self):
        s = self.call("buildSuggestions", self.WINDOWS, self.DESKTOP)
        self.assertEqual(len(self.call("filterSuggestions", s, "")), 4)
        self.assertEqual(len(self.call("filterSuggestions", s, "", 2)), 2)


if __name__ == "__main__":
    unittest.main()
