import unittest
import render

COLOURS = render.parse_colours("blue=10.1.0.1:8983 10.1.0.2:8983\ngreen=10.2.0.1:8983\n")


class ParseColours(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(COLOURS, {"blue": ["10.1.0.1:8983", "10.1.0.2:8983"], "green": ["10.2.0.1:8983"]})

    def test_rejects(self):
        for bad in ["", "Blue=1.1.1.1:1", "blue=", "blue=1.1.1.1", "blue=1.1.1.1:99999",
                    "blue=a:1\nblue=b:1", "blue=1.1.1.1:1;rm", "blue=x y:1"]:
            with self.assertRaises(render.ConfigError, msg=bad):
                render.parse_colours(bad)


class ParseWeights(unittest.TestCase):
    def test_properties_and_comma(self):
        for text in ["blue=120\ngreen=90\n", "blue=120,green=90", "# c\nblue = 120 # x\n\ngreen=90"]:
            self.assertEqual(render.parse_weights(text, COLOURS), {"blue": 120, "green": 90})

    def test_unknown_keys_ignored_missing_is_zero(self):
        self.assertEqual(render.parse_weights("other=5\nblue=1", COLOURS), {"blue": 1, "green": 0})

    def test_rejects(self):
        for bad in ["", "blue=0\ngreen=0", "other=5", "blue=-1", "blue=1.5", "blue=abc", "blue=1\nblue=2",
                    "blue=1000001", "blue=\n"]:
            with self.assertRaises(render.ConfigError, msg=bad):
                render.parse_weights(bad, COLOURS)


class Shares(unittest.TestCase):
    def test_120_90(self):
        active, h = render.shares({"blue": 120, "green": 90})
        self.assertEqual(active, ["blue", "green"])
        self.assertEqual(h, {"blue": 5714})          # 57.14%; green takes the remainder

    def test_single(self):
        self.assertEqual(render.shares({"blue": 0, "green": 5}), (["green"], {}))

    def test_tiny_weight_dropped(self):
        active, _ = render.shares({"blue": 1, "green": 1_000_000})
        self.assertEqual(active, ["green"])

    def test_three(self):
        active, h = render.shares({"a": 1, "b": 1, "c": 1})
        self.assertEqual(active, ["a", "b", "c"])
        self.assertEqual(h, {"a": 3333, "b": 3333})


class Render(unittest.TestCase):
    def test_split_and_backup(self):
        text = render.render(COLOURS, {"blue": 120, "green": 90})
        self.assertIn("  57.14% solr_blue;\n  * solr_green;", text)
        blue = text.split("upstream solr_blue {")[1].split("}")[0]
        self.assertIn("server 10.1.0.1:8983 max_fails", blue)
        self.assertIn("server 10.2.0.1:8983 backup", blue)
        self.assertNotIn("10.1.0.1:8983 backup", blue)

    def test_zero_weight_colour_is_not_a_backup_and_gets_no_share(self):
        text = render.render(COLOURS, {"blue": 5, "green": 0})
        self.assertIn("  * solr_blue;", text)
        self.assertNotIn("%", text.split("split_clients")[1])
        self.assertNotIn("backup", text)

    def test_deterministic(self):
        self.assertEqual(render.render(COLOURS, {"blue": 1, "green": 2}), render.render(COLOURS, {"green": 2, "blue": 1}))


if __name__ == "__main__":
    unittest.main()
