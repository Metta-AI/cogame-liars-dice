import std/[json, strutils]

type
  LiarsDiceError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  Mode* = enum
    mDice = "dice"    ## faces 1..6, five dice per seat
    mPoker = "poker"  ## digits 0..9, an eight-digit serial per seat

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    mode*: Mode
    handSize*: int        ## symbols dealt to every seat each deal
    deals*: int           ## independent deals in the episode
    maxBidsPerDeal*: int  ## bids before the sim forces a challenge
    talk*: bool           ## cheap talk: a `say` may ride every action
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  EventKind* = enum
    evStart = "start"
    evDeal = "deal"
    evBid = "bid"
    evChallenge = "challenge"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    deal*: int            ## 0-based deal; end: deals played; start: -1
    seat*: int            ## bid: bidder slot; challenge: challenger slot
    other*: int           ## challenge: the bidder's slot
    opener*: int          ## deal: the opening seat's slot
    quantity*: int        ## bid/challenge: the bid quantity
    face*: int            ## bid/challenge: the bid face
    actual*: int          ## challenge: real count of `face` across all hands
    counts*: seq[int]     ## challenge: per-slot count of `face`
    hands*: seq[seq[int]] ## deal: every seat's hand, slot-indexed
    bidderWins*: bool     ## challenge: the standing bid was true
    forced*: bool         ## challenge: forced by the bid cap
    scripted*: bool       ## the action came from a scripted baseline
    fallback*: bool       ## the LLM reply was rejected twice
    say*: string          ## table talk carried by the action
    notes*: string        ## the actor's private notes after the reply
    text*: string         ## end: the reason

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    mode: mDice,
    handSize: 5,
    deals: 8,
    maxBidsPerDeal: 12,
    talk: true,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 250,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 30
  )

proc parseMode*(text: string): Mode =
  case text.strip().toLowerAscii()
  of "dice": mDice
  of "poker": mPoker
  else: raise newException(LiarsDiceError, "mode must be dice or poker: " & text)

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(LiarsDiceError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("mode"):
    config.mode = parseMode(node["mode"].getStr())
  if node.hasKey("handSize"):
    config.handSize = node["handSize"].getInt()
  if node.hasKey("deals"):
    config.deals = node["deals"].getInt()
  if node.hasKey("maxBidsPerDeal"):
    config.maxBidsPerDeal = node["maxBidsPerDeal"].getInt()
  if node.hasKey("talk"):
    config.talk = node["talk"].getBool()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.deals < 2:
    raise newException(LiarsDiceError, "deals must be at least 2")
  if config.handSize < 1:
    raise newException(LiarsDiceError, "handSize must be at least 1")
  if config.maxBidsPerDeal < 1:
    raise newException(LiarsDiceError, "maxBidsPerDeal must be at least 1")
