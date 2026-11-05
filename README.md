# BreachEngine — M1 – M8 (M9 Partial) drop

> [!IMPORTANT]
>
> The InfiltrationEngine assets that Cish has made source-available [here](https://github.com/MoonstoneSkies/InfiltrationEngine-Custom-Missions) are distributed under the [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) license.
>
> This is also a open source implementation of InfiltrationEngine by simply looking at the tools; I do not profit from any of my projects, and would never want to profit from them.
>
> **Third-party content and paid-access restrictions**
>
> BreachEngine does not grant access to InfiltrationEngine, Entry Point: Freelancer's Cut, Operators, or any other paid-access experiences.
>
> This repository does not intend to redistribute paid-access game content, bypass access restrictions, or provide unauthorized copies of game assets.
>
> Any third-party assets used by the demonstration must be independently obtained through authorized means and used in accordance with their respective licenses and applicable terms.
>
> BreachEngine is an independent hobby project and is not affiliated with or endorsed by Cish.
>
> poweredbyLuau(Breach), "Breach Together, Forever. Even if you pick up a shotgun and shoot it."

Anthropic, give me a HIGHER limit please.

```
docs/           BreachEngine_Documentation.md  (main spec, v0.24)
                BreachEngine_Appendix_A_Attributes.md   (289 components / 1,746 attributes, generated)
                BreachEngine_M8_Bots_Plan.md            (the plan for bots: data survey, follower design, hostages, milestones)
                BreachEngine_Appendix_B_WireFormat.md   (wire-format tables, generated, rev 2)
breach-codec/   portable pure-Luau libraries + tests   (start with its README.md)
                  BreachCodec.luau     mission-code decoder          (M1)
                  BreachZstd.luau      Zstandard decompressor        (M1)
                  BreachValidator.luau attribute validator           (M2)
                  BreachMission.luau   mission model + indexes       (M3)
                  BreachStandalone.luau on-disk map format           (M3)
                  BreachWorld.luau     cells, links, nav graph, A*   (M4)
                  BreachExpr.luau      expression language           (M5)
                  BreachRandom.luau    seeded random                 (M5)
                  BreachLogic.luau     variables + replication, StateUpdate, Notification, TimerComponent, Mission triggers, StateScript (M5/M6)
                  BreachScript.luau    StateScript VM                (M6)
                  BreachCFrame.luau    portable CFrame math          (M6)
                  BreachProps.luau     players, zones, rooms, items, triggers, doors, readers, end zones (M7)
                  BreachSetup.luau     MissionSetup (SetupSource) data parser (M8.0)
                  BreachNav.luau       kinematic agents, trail following, anti-collision rules (M8a)
                  BreachBots.luau      bots: routes, patrols, loadouts, despawn, state trackers (M8b)
                  BreachSight.luau     vision cones, line of sight, detection meters (M8c)
                  BreachTrespass.luau  Cells rule sets, disguises, enforcing classes, witnesses (M8c)
                  BreachAlert.luau     alert level, AlertRaiseCondition, guard reactions, anomalies (M8c)
                  BreachHostage.luau   hostages, bodies, BotAltTrigger / BodyAltTrigger (M8d)
                  BreachBehavior.luau  CustomBehavior scripts, conditions, alarm overrides, bot spawners (M8e)
                  BreachSession.luau   one running mission: step order + combined event log (M8f)
```

Quick check:  `cd breach-codec && luau tests/run.luau && luau tests/localfile.luau`
