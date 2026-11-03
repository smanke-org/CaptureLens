# SnagAnything

Design rules: `design/DESIGN-SYSTEM.md`. Use its tokens (`Sources/CaptureLens/UI/Tokens.swift`);
never raw colors, radii, or durations.

Drive the app with `snag` (the app binary; `snag help`). See `.claude/skills/snag/SKILL.md`. Commands live in
`Sources/CaptureLens/Agent/AgentCommands.swift`; test them on a Debug build with `APP_STORE=/tmp/<name>`,
which starts a test copy on its own library and settings (Release builds ignore it).
