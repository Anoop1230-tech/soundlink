from soundbank.cli import main


def test_demo_runs_whole_story(capsys):
    main(["demo", "--profile", "fast"])
    out = capsys.readouterr().out
    assert "shop refuses (double spending" in out
    assert "settled_fraud" in out
    assert "frozen=True" in out
    assert "Rs 680.00 online" in out  # loaded 300, spent 320, bank takes back 20
