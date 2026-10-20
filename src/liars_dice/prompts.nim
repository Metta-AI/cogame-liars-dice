## Episode-stable wording, independent of the deal RNG and operator strategy.
import std/[json, strutils]
import crunchy
import sim

const PromptBankVersion* = "liars-dice-rules-v1"
const Templates = [
  staticRead("prompts/plain.txt"),
  staticRead("prompts/numbered.txt"),
  staticRead("prompts/questions.txt"),
  staticRead("prompts/reordered.txt"),
  staticRead("prompts/heldout-briefing.txt"),
  staticRead("prompts/heldout-reference.txt")
]

proc renderVariantPrompt*(sim: Sim, seat: int): string =
  let dice = sim.config.mode == mDice
  let symbols = if dice: "dice" else: "digits"
  let deal = if dice:
      "Every deal each cog receives " & $sim.config.handSize &
      " hidden dice with faces 1 to 6. You see only your own dice."
    else:
      "Every deal each cog receives a hidden " & $sim.config.handSize &
      "-digit serial number with digits 0 to 9. You see only your own serial."
  let bid = "There are " & $sim.totalSymbols() & " " & symbols &
    " in all. A bid concerns ALL of them: \"6 x 2\" claims that at least six show 2. " &
    (if dice: "Ones are NOT wild; each die counts only for its own face."
     else: "Each digit counts only for its own value.")
  let talk = if sim.config.talk:
      "Any action may include one line of public table talk, at most " & $MaxSayLen &
      " characters. Everyone sees it. This is cheap talk: neither your words nor anyone else's are binding."
    else: ""
  result = Templates[ord(sim.config.selectedPromptVariant) - 1] %
    [sim.names[seat], $(sim.seats() - 1), deal, bid, talk]
  result.add("\nOUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis, no\n" &
    "explanation, no markdown fences, no text before or after the object. Your reply\n" &
    "must begin with the character { and end with }.")

proc promptMetadata*(config: GameConfig, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $config.selectedPromptVariant,
    "selection": $config.promptVariant, "seed": config.promptSeed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}
