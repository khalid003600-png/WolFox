import pathlib
import plistlib
import tempfile
import unittest

from Tools.set_app_display_name import set_app_display_name


class SetAppDisplayNameTests(unittest.TestCase):
    def test_updates_app_label_but_preserves_bundle_identifier(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = pathlib.Path(temporary) / "YouTube.app"
            app.mkdir()
            info = {
                "CFBundleIdentifier": "com.google.ios.youtube",
                "CFBundleName": "YouTube",
                "CFBundleDisplayName": "YouTube",
                "CFBundleExecutable": "YouTube",
            }
            (app / "Info.plist").write_bytes(
                plistlib.dumps(info, fmt=plistlib.FMT_BINARY)
            )

            set_app_display_name(app, "WolFox")

            result = plistlib.loads((app / "Info.plist").read_bytes())
            self.assertEqual(result["CFBundleIdentifier"], "com.google.ios.youtube")
            self.assertEqual(result["CFBundleExecutable"], "YouTube")
            self.assertEqual(result["CFBundleDisplayName"], "WolFox")
            self.assertEqual(result["CFBundleName"], "WolFox")

    def test_renames_main_executable_and_preserves_youtube_bundle_identifier(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = pathlib.Path(temporary) / "YouTube.app"
            app.mkdir()
            original_executable = app / "YouTube"
            original_executable.write_bytes(b"test executable")
            info = {
                "CFBundleIdentifier": "com.google.ios.youtube",
                "CFBundleName": "YouTube",
                "CFBundleDisplayName": "YouTube",
                "CFBundleExecutable": "YouTube",
            }
            (app / "Info.plist").write_bytes(
                plistlib.dumps(info, fmt=plistlib.FMT_BINARY)
            )

            set_app_display_name(app, "WolFox", "WolFox")

            result = plistlib.loads((app / "Info.plist").read_bytes())
            self.assertEqual(result["CFBundleIdentifier"], "com.google.ios.youtube")
            self.assertEqual(result["CFBundleExecutable"], "WolFox")
            self.assertFalse(original_executable.exists())
            self.assertEqual((app / "WolFox").read_bytes(), b"test executable")

    def test_updates_localized_openstep_strings(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = pathlib.Path(temporary) / "YouTube.app"
            locale = app / "en.lproj"
            locale.mkdir(parents=True)
            (app / "Info.plist").write_bytes(
                plistlib.dumps({"CFBundleIdentifier": "com.google.ios.youtube"})
            )
            strings = locale / "InfoPlist.strings"
            strings.write_text(
                '"CFBundleDisplayName" = "YouTube";\n'
                '"CFBundleName" = "YouTube";\n'
                '"CFBundleIdentifier" = "com.google.ios.youtube";\n',
                encoding="utf-8",
            )

            set_app_display_name(app, "WolFox")

            text = strings.read_text(encoding="utf-8")
            self.assertIn('"CFBundleDisplayName" = "WolFox";', text)
            self.assertIn('"CFBundleName" = "WolFox";', text)
            self.assertIn('"CFBundleIdentifier" = "com.google.ios.youtube";', text)

    def test_does_not_rebrand_nested_safari_extension(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = pathlib.Path(temporary) / "YouTube.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(
                plistlib.dumps({"CFBundleIdentifier": "com.google.ios.youtube"})
            )
            extension = app / "PlugIns" / "OpenInWolFox.appex"
            locale = extension / "en.lproj"
            locale.mkdir(parents=True)
            extension_strings = locale / "InfoPlist.strings"
            extension_strings.write_text(
                '"CFBundleDisplayName" = "Open in WolFox";\n', encoding="utf-8"
            )

            set_app_display_name(app, "WolFox")

            self.assertIn('"CFBundleDisplayName" = "Open in WolFox";',
                          extension_strings.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
