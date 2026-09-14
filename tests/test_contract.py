from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADDON = (ROOT / "ArcaneShredderUI" / "ArcaneShredderUI.lua").read_text(encoding="utf-8")
TOC = (ROOT / "ArcaneShredderUI" / "ArcaneShredderUI.toc").read_text(encoding="utf-8")


class AddonContractTest(unittest.TestCase):
    def test_uses_only_hidden_addon_transport(self):
        self.assertIn('local PREFIX = "AzerothCore"', ADDON)
        self.assertIn("SendAddonMessage(PREFIX", ADDON)
        self.assertIn("if RegisterAddonMessagePrefix then", ADDON)
        self.assertIn("RegisterAddonMessagePrefix(PREFIX)", ADDON)
        self.assertIn('RegisterEvent("CHAT_MSG_ADDON")', ADDON)
        self.assertNotIn("SendChatMessage", ADDON)
        self.assertNotIn("CHAT_MSG_SYSTEM", ADDON)

    def test_uses_stock_wotlk_item_cache_polling(self):
        self.assertNotIn('RegisterEvent("GET_ITEM_INFO_RECEIVED")', ADDON)
        self.assertIn("window.needsItemRefresh and now - lastItemRefresh >= 1", ADDON)

    def test_parses_every_server_protocol_record(self):
        for record in (
            "HELLO",
            "BEGIN",
            "WARN",
            "ITEM",
            "END",
            "EXCLUDED",
            "CANCELLED",
            "RESULT",
            "SKIP",
            "STATUS",
            "ERR",
        ):
            with self.subTest(record=record):
                self.assertIn(f'record == "{record}"', ADDON)

    def test_emits_supported_machine_commands(self):
        for command in (
            "ashred hello ",
            "ashred preview ",
            "ashred exclude ",
            "ashred cancel ",
            "ashred confirm ",
        ):
            with self.subTest(command=command):
                self.assertIn(command, ADDON)

    def test_largest_item_record_fits_azerothcore_addon_envelope(self):
        record = (
            "ASHRED:ITEM:"
            + "F" * 16
            + ":18446744073709551615:4294967295:4:1000:31:255:255"
        )
        envelope = "AzerothCore\t" + "m" + "FFFF" + record
        self.assertLessEqual(len(envelope.encode("utf-8")), 255)

    def test_uses_server_preview_ttl_for_confirmation_safety(self):
        self.assertIn("local ttl = tonumber(fields[4])", ADDON)
        self.assertIn("previewExpiresAt = buildingPreview.expiresAt", ADDON)
        self.assertIn("if previewExpiresAt and GetTime() >= previewExpiresAt", ADDON)
        self.assertIn("if now >= previewExpiresAt", ADDON)

    def test_validates_filters_before_preview(self):
        validation_start = ADDON.index("FiltersValid = function()")
        request_start = ADDON.index("local function RequestPreview()")
        request_end = ADDON.index("\nend\n", request_start)
        self.assertLess(validation_start, request_start)
        self.assertIn("local valid, message = FiltersValid()", ADDON[request_start:request_end])
        self.assertIn("RestoreSafeDefaults", ADDON)

    def test_destructive_action_shows_preview_item_count(self):
        self.assertIn("confirmButton:SetText(string.format(L.CONFIRM_COUNT, #previewItems))", ADDON)
        self.assertIn("confirmTexture:SetVertexColor(0.9, 0.28, 0.22)", ADDON)

    def test_targets_wotlk_335a(self):
        self.assertIn("## Interface: 30300", TOC)
        self.assertIn("## Version: 1.0.1", TOC)


if __name__ == "__main__":
    unittest.main()
