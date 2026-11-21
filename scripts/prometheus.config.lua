-- Prometheus obfuscation config for the SERVED copy of unsyk.lua (scripts/obfuscate.sh).
-- RENAME-ONLY ON PURPOSE: no Steps. Prometheus still strips comments/whitespace and renames every LOCAL;
-- globals (entity, rage, aa, plist, UNSYK_AUTH, UNSYK_VERSION, ...) are never touched.
--   * EncryptStrings / ConstantArray (beta #13-#14) dropped the game to ~10 fps: in Lua every field
--     access (`st.x`, `obj.Text`) is a string constant, so both steps turn every field read in the paint
--     and tick callbacks into a function call + table lookup. Readable #15 (same code) was back to normal.
--   * The VM presets (Vmify) also grow the script to ~29 MB, which cannot download or compile in game.
-- Do not add a step that rewrites string constants or expressions without an fps test on the beta first.
return {
    LuaVersion    = "Lua51",
    VarNamePrefix = "",
    NameGenerator = "MangledShuffled",
    PrettyPrint   = false,
    Seed          = 0,
    Steps = {},
}
