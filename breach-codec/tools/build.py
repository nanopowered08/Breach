#!/usr/bin/env python3
"""Assemble the single-file libraries: hand-written source with generated data spliced in."""
JOBS = [("src/body.luau", [("--@@TABLES@@", "src/tables.inc"), ("--@@JSON@@", "src/json.inc")], "BreachCodec.luau"),
        ("src/validator.luau", [("--@@ATTRMAP@@", "src/attrmap.inc")], "BreachValidator.luau"),
        ("src/mission.luau", [], "BreachMission.luau"),
        ("src/standalone.luau", [("--@@JSON@@", "src/json.inc")], "BreachStandalone.luau"),
        ("src/world.luau", [("--@@JSON@@", "src/json.inc")], "BreachWorld.luau"),
        ("src/expr.luau", [], "BreachExpr.luau"),
        ("src/random.luau", [], "BreachRandom.luau"),
        ("src/cframe.luau", [], "BreachCFrame.luau"),
        ("src/setup.luau", [], "BreachSetup.luau"),
        ("src/nav.luau", [], "BreachNav.luau"),
        ("src/sight.luau", [], "BreachSight.luau"),
        ("src/trespass.luau", [], "BreachTrespass.luau"),
        ("src/alert.luau", [], "BreachAlert.luau"),
        ("src/hostage.luau", [], "BreachHostage.luau"),
        ("src/behavior.luau", [], "BreachBehavior.luau"),
        ("src/session.luau", [], "BreachSession.luau"),
        ("src/combat_data.luau", [], "BreachCombatData.luau"),
        ("src/shuffle.luau", [], "BreachShuffle.luau"),
        ("src/combat.luau", [("--@@RANDOM@@", "src/random.luau")], "BreachCombat.luau"),
        ("src/bots.luau", [("--@@RANDOM@@", "src/random.luau")], "BreachBots.luau"),
        ("src/props.luau", [("--@@CFRAME@@", "src/cframe.luau")], "BreachProps.luau"),
        ("src/script_standalone.luau", [("--@@RANDOM@@", "src/random.luau"), ("--@@EXPR@@", "src/expr.luau"), ("--@@CFRAME@@", "src/cframe.luau"), ("--@@SCRIPT@@", "src/script.luau")], "BreachScript.luau"),
        ("src/logic.luau", [("--@@RANDOM@@", "src/random.luau"), ("--@@EXPR@@", "src/expr.luau"), ("--@@CFRAME@@", "src/cframe.luau"), ("--@@SCRIPT@@", "src/script.luau")], "BreachLogic.luau")]
for src_f, incs, out_f in JOBS:
    text = open(src_f, encoding="utf-8").read()
    for marker, inc_f in incs:
        assert marker in text, (src_f, marker)
        inc = open(inc_f, encoding="utf-8").read().rstrip("\n")
        if inc.startswith("--!"):  # a spliced module must not carry its own file directive
            inc = inc.split("\n", 1)[1]
        text = text.replace(marker, inc)
    open(out_f, "w", encoding="utf-8").write(text)
    print("built", out_f)
import shutil; shutil.copyfile("src/zstd.luau", "BreachZstd.luau"); print("copied BreachZstd.luau")
