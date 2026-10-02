## Private authoritative decisions, separate from spectator artifacts.
import std/[json, options]
import bitworld/decision_trajectory
import llm, sim

proc recordAppliedDecision*(trajectory: DecisionTrajectory, before, after: Sim,
    seat: int, proposed: Decision, operatorPrompt: string,
    deliberateTeacher: bool, fallbackReason = "") =
  var applied = newJNull()
  for index in before.events.len ..< after.events.len:
    let event = after.events[index]
    if event.seat == seat and event.kind in {evBid, evChallenge}:
      let actual = Decision(action: (if event.kind == evBid: aBid else: aChallenge),
        quantity: event.quantity, face: event.face, say: event.say, notes: event.notes)
      applied = before.decisionAction(actual)
      break
  doAssert applied.kind == JObject, "engine emitted no applied decision event"
  var attempts = proposed.nativeAttempts
  var selected = none(string)
  let fallback = proposed.fallback or fallbackReason.len > 0
  if not fallback and attempts.len == 0:
    let origin = if deliberateTeacher: aoTeacher else: aoUnknown
    var evidence = newDecisionAttempt("event-" & $before.events.len & "-applied",
      if deliberateTeacher: proposed.policy else: "external-liars-dice", origin)
    if deliberateTeacher:
      evidence.prompt = %*[{"role": "system", "content": systemPrompt(before, seat)},
        {"role": "user", "content": userPrompt(before, seat, operatorPrompt)}]
      evidence.response = %($before.decisionAction(proposed))
    else:
      evidence.response = %proposed.submittedResponse
    evidence.parsedAction = before.decisionAction(proposed)
    evidence.accepted = true
    attempts.add(evidence)
  for index in 0 ..< attempts.len:
    if attempts[index].accepted:
      if fallback:
        attempts[index].accepted = false
        attempts[index].rejectionReason = some(if fallbackReason.len > 0: fallbackReason else: "consumed fallback")
      else:
        selected = some(attempts[index].attemptId)
  let observation = %*{"seat": seat, "system": systemPrompt(before, seat),
    "user": userPrompt(before, seat, operatorPrompt)}
  trajectory.recordDecision("event-" & $before.events.len, $seat,
    observation, attempts, selected, applied,
    if fallback: asFallback else: asAccepted, terminal = after.done,
    fallbackOrigin = if fallback: some(if fallbackReason.len > 0: fallbackReason else: proposed.policy) else: none(string))

proc finishTrajectory*(trajectory: DecisionTrajectory, sim: Sim) =
  let outcome = sim.resultsJson()
  var participants = newJObject()
  for seat in 0 ..< sim.config.players.len:
    participants[$seat] = %*{"score": outcome["scores"][seat]}
  trajectory.finish(if sim.reason == "complete": esCompleted else: esTruncated,
    outcome, participants)
