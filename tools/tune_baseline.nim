## Grid-sweep tuning harness for the scripted baseline's two thresholds.
##
## `BayesChallenge` / `BayesSafe` in `src/liars_dice/llm.nim` are the pick of
## THIS sweep, not a guess. The sweep is a full round robin over a lattice of
## `(chal, safe)` points: every point plays every other point head to head,
## two seats each, at four seats a table, both seatings, over a fixed list of
## seeds and both modes. A point's score is the mean of `sim.score` over every
## seat it held, so 0.5 is break even against the whole searched surface.
##
## The surface is a plateau, not a peak: ten of its 110 points sit within
## 2 s.e. of the argmax, because `pTrue` only ever takes discrete values and a
## threshold matters solely when it crosses one. So the pick is the CENTRE of the
## winning plateau rather than its noise-selected argmax, and the check below
## passes for any point that is paired-tied with the argmax.
##
## The shipped `pressure` filler (chal 0.25, safe 0.35, pad) is NOT a grid
## point: it is a deliberate foil, so it is reported as a separate column
## (each grid point's mean score against a table of two pressure seats) and
## never as a candidate.
##
## Usage:
##   nim r -d:release --path:src tools/tune_baseline.nim
##       the full sweep; writes data/tuning/threshold_sweep.tsv
##   nim r -d:release --path:src tools/tune_baseline.nim --check
##       the CI slice: the same lattice over fewer seeds, dice only, printing
##       the table and EXITING NON-ZERO unless the shipped point is the grid
##       optimum or paired-tied with it.
##
## Flags: --check, --seeds:N, --deals:N, --out:PATH, --quiet

import
  std/[math, os, parseopt, strformat, strutils, times],
  liars_dice/[llm, sim]

const
  ## The lattice. `chal` spans "call almost nothing" to "call anything under
  ## even money"; `safe` spans "raise on a coin flip" to "raise only on a bid
  ## I nearly hold myself". Both shipped baselines' thresholds lie inside it.
  ChalGrid = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50,
    0.55]
  SafeGrid = [0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70]
  ## The shipped point under test, read from the source of truth.
  Shipped: Thresholds = (BayesChallenge, BayesSafe, false)
  Pressure: Thresholds = (PressureChallenge, PressureSafe, true)
  MatchSeats = 4
  ## Seeds are replicates: every statistic below is paired across them.
  FullSeeds = 24
  CheckSeeds = 8
  MatchDeals = 30
  DefaultOut = "data/tuning/threshold_sweep.tsv"

type
  Cell = object
    chal, safe: float
    ## Per-seed sums, one entry per replicate seed.
    scoreBySeed: seq[float]
    seatsBySeed: seq[int]
    vsPressureScore: float
    vsPressureSeats: int

proc label(chal, safe: float): string =
  &"{chal:.2f}/{safe:.2f}"

proc matchConfig(seed: int, mode: Mode, deals: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.mode = mode
  result.handSize = if mode == mPoker: 8 else: 5
  result.deals = deals
  ## The baselines never speak, so talk off keeps the episode honest and the
  ## sweep cheap.
  result.talk = false
  ## Already sized deliberately; do not let the call budget resample it.
  result.sampled = true
  for index in 0 ..< MatchSeats:
    result.players.add(PlayerConfig(name: "S" & $index))
    result.tokens.add("t" & $index)

proc playMatch(client: LlmClient, config: GameConfig,
    seating: array[MatchSeats, Thresholds]): array[MatchSeats, float] =
  ## One whole episode driven by the scripted rule alone, one threshold pair
  ## per slot. Returns each slot's score.
  var sim = initSim(config)
  while not sim.done:
    let turn = sim.currentTurn()
    case turn.kind
    of tkDeal:
      sim.beginDeal()
    of tkAct:
      let decision = client.scriptedActionWith(sim, turn.seat,
        seating[turn.seat])
      if decision.action == aBid:
        sim.applyBid(turn.seat, decision.quantity, decision.face,
          scripted = true)
      else:
        sim.applyChallenge(turn.seat, scripted = true)
    of tkNone:
      discard
  for slot in 0 ..< MatchSeats:
    result[slot] = sim.score(slot)

proc mean(values: openArray[float]): float =
  if values.len == 0: return 0.0
  for value in values:
    result += value
  result / values.len.float

proc stdev(values: openArray[float]): float =
  ## Sample standard deviation; 0 for fewer than two values.
  if values.len < 2: return 0.0
  let m = mean(values)
  var total = 0.0
  for value in values:
    total += (value - m) * (value - m)
  sqrt(total / (values.len - 1).float)

proc perSeedMeans(cell: Cell): seq[float] =
  for index in 0 ..< cell.scoreBySeed.len:
    result.add(
      if cell.seatsBySeed[index] == 0: 0.5
      else: cell.scoreBySeed[index] / cell.seatsBySeed[index].float)

proc main() =
  var
    check = false
    quiet = false
    outPath = ""
    seedCount = -1
    deals = -1
  for kind, key, value in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "check": check = true
      of "quiet": quiet = true
      of "out": outPath = value
      of "seeds": seedCount = parseInt(value)
      of "deals": deals = parseInt(value)
      else:
        quit("unknown flag: --" & key, 2)
    else:
      quit("unexpected argument: " & key, 2)
  if seedCount < 0:
    seedCount = if check: CheckSeeds else: FullSeeds
  if deals < 0:
    deals = MatchDeals
  if outPath.len == 0 and not check:
    outPath = DefaultOut
  ## The CI slice is dice only; the full sweep also plays poker, where the
  ## same thresholds run against ten faces instead of six.
  let modes = if check: @[mDice] else: @[mDice, mPoker]

  var cells: seq[Cell]
  for chal in ChalGrid:
    for safe in SafeGrid:
      cells.add(Cell(chal: chal, safe: safe,
        scoreBySeed: newSeq[float](seedCount),
        seatsBySeed: newSeq[int](seedCount)))

  let started = getTime()
  var matches = 0
  for mode in modes:
    for seedIndex in 0 ..< seedCount:
      ## One client per (mode, seed) block: `scriptedActionWith` draws from it
      ## only to break an exact probability tie, and both sides of every match
      ## draw from the same stream, so neither seat is favoured.
      let seed = 1000 + seedIndex * 17
      let config = matchConfig(seed, mode, deals)
      let client = newLlmClient(config)
      for a in 0 ..< cells.len:
        for b in a + 1 ..< cells.len:
          let one: Thresholds = (cells[a].chal, cells[a].safe, false)
          let two: Thresholds = (cells[b].chal, cells[b].safe, false)
          ## Both seatings: slots 0/2 and slots 1/3 do not face the same
          ## opening rotation, so each pair plays it from both sides.
          for orientation in 0 .. 1:
            let seating: array[MatchSeats, Thresholds] =
              if orientation == 0: [one, two, one, two]
              else: [two, one, two, one]
            let scores = playMatch(client, config, seating)
            inc matches
            for slot in 0 ..< MatchSeats:
              let isA = (slot mod 2 == 0) == (orientation == 0)
              let index = if isA: a else: b
              cells[index].scoreBySeed[seedIndex] += scores[slot]
              cells[index].seatsBySeed[seedIndex] += 1
      ## The deployment column: every grid point against two pressure seats.
      for index in 0 ..< cells.len:
        let point: Thresholds = (cells[index].chal, cells[index].safe, false)
        for orientation in 0 .. 1:
          let seating: array[MatchSeats, Thresholds] =
            if orientation == 0: [point, Pressure, point, Pressure]
            else: [Pressure, point, Pressure, point]
          let scores = playMatch(client, config, seating)
          inc matches
          for slot in 0 ..< MatchSeats:
            let isPoint = (slot mod 2 == 0) == (orientation == 0)
            if isPoint:
              cells[index].vsPressureScore += scores[slot]
              cells[index].vsPressureSeats += 1
  let elapsed = (getTime() - started).inMilliseconds

  ## Rank: the round-robin mean against the whole lattice.
  var means: seq[float]
  for cell in cells:
    means.add(mean(cell.perSeedMeans()))
  var order: seq[int]
  for index in 0 ..< cells.len:
    order.add(index)
  for i in 1 ..< order.len:
    var j = i
    while j > 0 and means[order[j]] > means[order[j - 1]]:
      swap(order[j], order[j - 1])
      dec j

  var shippedIndex = -1
  for index, cell in cells:
    if abs(cell.chal - Shipped.chal) < 1e-9 and
        abs(cell.safe - Shipped.safe) < 1e-9:
      shippedIndex = index
  if shippedIndex < 0:
    quit("the shipped point " & label(Shipped.chal, Shipped.safe) &
      " is not on the lattice; widen ChalGrid/SafeGrid", 2)
  let best = order[0]
  var shippedRank = 0
  for rank, index in order:
    if index == shippedIndex:
      shippedRank = rank + 1

  ## Paired comparison against the grid optimum: the difference is taken seed
  ## by seed, so the seeds cancel and the remaining spread is the sampling
  ## error of the difference itself.
  let bestBySeed = cells[best].perSeedMeans()
  proc pairedAgainstBest(index: int): tuple[gap, band: float] =
    let bySeed = cells[index].perSeedMeans()
    var diffs: seq[float]
    for seedIndex in 0 ..< bestBySeed.len:
      diffs.add(bestBySeed[seedIndex] - bySeed[seedIndex])
    (mean(diffs), 2.0 * stdev(diffs) / sqrt(diffs.len.float))

  let (gap, band) = pairedAgainstBest(shippedIndex)
  let tied = gap <= band
  let winner = shippedIndex == best
  var plateau = 0
  for index in 0 ..< cells.len:
    let (cellGap, cellBand) = pairedAgainstBest(index)
    if index == best or cellGap <= cellBand:
      inc plateau

  var report: string
  report.add("# liars-dice scripted-baseline threshold sweep\n")
  report.add("# harness: tools/tune_baseline.nim" &
    (if check: " --check" else: "") & "\n")
  report.add(&"# lattice: chal {ChalGrid[0]:.2f}..{ChalGrid[^1]:.2f}, " &
    &"safe {SafeGrid[0]:.2f}..{SafeGrid[^1]:.2f}, step 0.05 " &
    &"({cells.len} points)\n")
  report.add(&"# design: full round robin, {MatchSeats} seats, two seats per " &
    &"point, both seatings,\n#         {seedCount} seeds x {deals} deals x " &
    &"{modes.len} mode(s) = {matches} episodes ({elapsed} ms)\n")
  report.add("# score: mean sim.score over every seat the point held " &
    "(0.5 = break even vs the lattice)\n")
  report.add(&"# shipped point: {label(Shipped.chal, Shipped.safe)} " &
    &"(BayesChallenge/BayesSafe), rank {shippedRank} of {cells.len}\n")
  report.add(&"# grid optimum: {label(cells[best].chal, cells[best].safe)} " &
    &"score {means[best]:.5f}; shipped {means[shippedIndex]:.5f}; " &
    &"paired gap {gap:.5f} (2 s.e. band {band:.5f}) -> " &
    (if winner: "shipped IS the optimum"
     elif tied: "tied" else: "SHIPPED IS BEATEN") & "\n")
  report.add(&"# plateau: {plateau} of {cells.len} points are paired-tied " &
    "with the optimum (2 s.e. of the paired difference)\n")
  report.add("rank\tchal\tsafe\tscore\tseSeed\tvsPressure\ttiedWithBest\t" &
    "shipped\n")
  for rank, index in order:
    let cell = cells[index]
    let bySeed = cell.perSeedMeans()
    let cellSe = stdev(bySeed) / sqrt(bySeed.len.float)
    let vsPressure =
      if cell.vsPressureSeats == 0: 0.5
      else: cell.vsPressureScore / cell.vsPressureSeats.float
    let (cellGap, cellBand) = pairedAgainstBest(index)
    report.add(&"{rank + 1}\t{cell.chal:.2f}\t{cell.safe:.2f}\t" &
      &"{means[index]:.5f}\t{cellSe:.5f}\t{vsPressure:.5f}\t" &
      (if index == best or cellGap <= cellBand: "tied" else: "-") & "\t" &
      (if index == shippedIndex: "<-- SHIPPED" else: "") & "\n")

  if not quiet:
    stdout.write(report)
  if outPath.len > 0:
    createDir(outPath.parentDir)
    writeFile(outPath, report)
    echo "wrote ", outPath
  if check:
    if winner:
      echo "OK: the shipped point ", label(Shipped.chal, Shipped.safe),
        " is the grid optimum over ", cells.len, " points"
    elif tied:
      echo "OK: the shipped point ", label(Shipped.chal, Shipped.safe),
        " is paired-tied with the optimum ",
        label(cells[best].chal, cells[best].safe), " (gap ",
        &"{gap:.5f}", " <= 2 s.e. ", &"{band:.5f}", ")"
    else:
      echo "FAIL: ", label(cells[best].chal, cells[best].safe),
        " beats the shipped ", label(Shipped.chal, Shipped.safe), " by ",
        &"{gap:.5f}", " > 2 s.e. ", &"{band:.5f}",
        " -- retune src/liars_dice/llm.nim to the winning cell"
      quit(1)

main()
