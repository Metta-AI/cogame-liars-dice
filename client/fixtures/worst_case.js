// Worst-case renderer fixture — the driver. See worst_case.html for why this
// page exists (acceptance checklist 15, last bullet: the CI replay cannot
// talk, so nothing else in this repo ever draws model-authored text).
//
// Everything here is fixture scaffolding: the renderer under test is the real
// client/renderer.js, driven through its real attachReplay entry point.
(function () {
  "use strict";

  // The server's caps on the two model-authored strings, from
  // src/liars_dice/sim.nim:27-28. The fixture's own strings are asserted to be
  // EXACTLY this long before and after every render: a quietly shortened
  // remark would leave this page green while testing nothing.
  var MAX_SAY_LEN = 140;
  var MAX_NOTES_LEN = 400;

  var CANVAS_SIZES = [
    [1280, 800], [1000, 560], [960, 640], [720, 480], [640, 360],
    [480, 720], [360, 640]
  ];

  var ALIASES = ["Sprocket", "Gizmo", "Ratchet", "Widget"];
  var POLICIES = ["liars-dice-calibrator", "liars-dice-needler",
    "Baseline (1)", "Baseline (2)"];

  function runes(text) {
    return Array.from(text);
  }

  // Pads to EXACTLY `n` runes (and refuses to shorten: a seed longer than the
  // cap is a bug in the fixture, not something to trim quietly).
  function exact(seed, n, filler) {
    var out = runes(seed);
    if (out.length > n) {
      throw new Error("fixture seed is longer than the cap: " + out.length +
        " > " + n);
    }
    var pad = runes(filler);
    var i = 0;
    while (out.length < n) {
      out.push(pad[i % pad.length]);
      i += 1;
    }
    return out.join("");
  }

  // Capitals: the widest run of glyphs a model can send, so the reserved band
  // is measured against the worst case it is sized for. No alias appears
  // verbatim, because the feed rewrites aliases to policy names.
  var SAY_SEEDS = [
    "FIVE SIXES? THAT IS A STORY AND WE BOTH KNOW IT. I HAVE WATCHED EVERY " +
      "CUP GO DOWN TONIGHT AND THE SIXES ARE SIMPLY NOT ON THIS TABLE",
    "I WILL RAISE IT AND I WILL NOT BLINK: MY OWN HAND CARRIES TWO OF THEM, " +
      "SO THE CLAIM ONLY NEEDS THREE MORE ACROSS NINE HIDDEN DICE",
    "CAREFUL NOW. THE LAST TIME THAT BID CAME OUT SO FAST IT WAS AIR, AND " +
      "THE WHOLE FELT PAID FOR IT, SO I AM RAISING ONE STEP AND WAITING",
    "LIAR. THAT IS THE THIRD CLAIM IN A ROW WITH NOTHING BEHIND IT AND I " +
      "AM CALLING IT RIGHT HERE BEFORE THE CAP FORCES ME TO CALL IT"
  ];
  // Mixed case with an unbreakable 44-character token: a word wider than the
  // band must be BROKEN, never ellipsized.
  var NOTES_SEEDS = [
    "Ledger — seat 2 opened light on three of the last four deals and folded " +
      "the argument the moment it was raised; treat any six claim from that " +
      "chair as air until proven. Key tag: COUNTERBLUFF-LEDGER-DEAL-03-SEAT-2" +
      "-ROLLING. Own hand: two fives, one six, one three, one two, so the " +
      "table needs four more sixes for the standing claim to hold, which the " +
      "tail says is under a third.",
    "Read — the chair to my left raises exactly one step every time it is " +
      "holding the face it names, and jumps two when it is not; that pattern " +
      "has held for eleven bids. Key tag: STEPSIZE-TELL-DEAL-03-SEAT-1-ROLLING" +
      ". Own hand: three fives. I can carry a five claim to seven before the " +
      "binomial tail turns against me, so I keep the face and push quantity.",
    "Plan — hold the face, push the quantity, and let the cap do the calling " +
      "for me: two more raises and the bid limit forces the seat on my right " +
      "to challenge into a claim I can actually cover. Key tag: " +
      "CAPSQUEEZE-PLAN-DEAL-03-SEAT-3-ROLLING. Own hand: one five, two sixes " +
      "and two ones, so a six claim of five is still comfortably live here.",
    "Doubt — the standing claim needs five sixes and I hold none at all, so " +
      "the other three chairs would have to be sitting on five between them; " +
      "the tail on that is roughly one in six. Key tag: " +
      "TAILCHECK-DOUBT-DEAL-03-SEAT-0-ROLLING. Calling now costs me one point " +
      "if I am wrong and gains one if I am right, and the odds are with me."
  ];

  var SAY = SAY_SEEDS.map(function (seed) {
    return exact(seed, MAX_SAY_LEN, " AND THAT IS THE WHOLE OF IT");
  });
  var NOTES = NOTES_SEEDS.map(function (seed) {
    return exact(seed, MAX_NOTES_LEN,
      " Revisit this read after the next reveal and adjust the tail.");
  });

  // ---- Payload -------------------------------------------------------------

  var HANDS = [[5, 5, 6, 3, 2], [5, 5, 5, 2, 1], [6, 6, 5, 1, 1],
    [4, 3, 2, 2, 1]];

  var EVENTS = [
    { kind: "start" },
    { kind: "deal", deal: 0, opener: 0, hands: HANDS },
    { kind: "bid", deal: 0, seat: 0, quantity: 3, face: 5, say: SAY[0],
      notes: NOTES[0] },
    { kind: "bid", deal: 0, seat: 1, quantity: 4, face: 5, say: SAY[1],
      notes: NOTES[1] },
    { kind: "bid", deal: 0, seat: 2, quantity: 5, face: 5, say: SAY[2],
      notes: NOTES[2] },
    { kind: "challenge", deal: 0, seat: 3, other: 2, quantity: 5, face: 5,
      actual: 4, counts: [2, 3, 1, 0], bidderWins: false, forced: false,
      say: SAY[3], notes: NOTES[3] },
    { kind: "end", deal: 1, text: "complete" }
  ];

  function stateAt(index) {
    var revealed = index >= 6;
    var done = index >= EVENTS.length;
    var seats = ALIASES.map(function (name, slot) {
      return {
        slot: slot,
        seat: slot,
        name: name,
        points: revealed ? (slot === 3 ? 1 : slot === 2 ? -1 : 0) : 0,
        score: 0.5,
        wins: revealed && slot === 3 ? 1 : 0,
        losses: revealed && slot === 2 ? 1 : 0,
        hand: HANDS[slot],
        revealed: revealed,
        acting: !done && !revealed && slot === index % 4,
        // Every seat talking at the cap, at once — the frame built to hurt.
        say: SAY[slot],
        notes: NOTES[slot]
      };
    });
    return {
      seats: seats,
      order: [0, 1, 2, 3],
      mode: "dice",
      faces: 6,
      lowFace: 1,
      handSize: 5,
      totalSymbols: 20,
      talk: true,
      deal: 0,
      deals: 3,
      dealsPlayed: revealed ? 1 : 0,
      opener: 0,
      turn: index % 4,
      bid: index >= 2 ?
        { seat: Math.min(index - 2, 2), quantity: 2 + Math.min(index - 2, 3),
          face: 5 } : null,
      resolution: revealed ?
        { challenger: 3, bidder: 2, quantity: 5, face: 5, actual: 4,
          counts: [2, 3, 1, 0], bidderWins: false, forced: false } : null,
      phase: done ? "done" : revealed ? "reveal" : "bidding",
      gameDone: done,
      reason: done ? "complete" : ""
    };
  }

  var PAYLOAD = {
    protocol: "liarsdice.replay.v1",
    names: ALIASES,
    policyNames: POLICIES,
    config: { mode: "dice", seats: 4, handSize: 5, faces: 6, deals: 3,
      talk: true, maxBidsPerDeal: 12, seed: 1, sampled: true,
      order: [0, 1, 2, 3] },
    events: EVENTS,
    states: EVENTS.map(function (_, i) { return stateAt(i); })
      .concat([stateAt(EVENTS.length)]),
    results: { names: ALIASES, scores: [0.5, 0.5, 0.25, 0.75],
      points: [0, 0, -1, 1], wins: [0, 0, 0, 1], losses: [0, 0, 1, 0],
      bids: [1, 1, 1, 0], challenges: [0, 0, 0, 1],
      bluffRate: [0.0, 0.5, 1.0, 0.0], deals: 1, reason: "complete" }
  };

  // ---- Instrumentation -----------------------------------------------------

  // The renderer sets data-replay-loaded on its FIRST drawn frame. Hold that
  // signal until every canvas size has been rendered and checked, or
  // viewer_smoke.mjs would report success from frame one.
  var root = document.documentElement;
  var realSetAttribute = root.setAttribute.bind(root);
  var rendererSignalled = false;
  root.setAttribute = function (name, value) {
    if (name === "data-replay-loaded") {
      rendererSignalled = true;
      return undefined;
    }
    return realSetAttribute(name, value);
  };

  // Every fillText/strokeText, with its measured box against its own canvas.
  var drawn = [];
  var outside = [];
  (function hook() {
    var proto = window.CanvasRenderingContext2D &&
      window.CanvasRenderingContext2D.prototype;
    if (!proto) return;
    ["fillText", "strokeText"].forEach(function (name) {
      var real = proto[name];
      if (typeof real !== "function") return;
      proto[name] = function (text, x, y) {
        var out = real.apply(this, arguments);
        try {
          var str = String(text);
          drawn.push(str);
          var canvas = this.canvas;
          if (!canvas || !canvas.width || !canvas.height) return out;
          var m = this.measureText(str);
          var left = x;
          if (this.textAlign === "center") left = x - m.width / 2;
          else if (this.textAlign === "right" || this.textAlign === "end") {
            left = x - m.width;
          }
          var top = y - (m.actualBoundingBoxAscent || 0);
          var bottom = y + (m.actualBoundingBoxDescent || 0);
          var right = left + m.width;
          var edges = [];
          if (top < -1) edges.push("top");
          if (left < -1) edges.push("left");
          if (bottom > canvas.height + 1) edges.push("bottom");
          if (right > canvas.width + 1) edges.push("right");
          if (edges.length) {
            outside.push(edges.join("+") + " [" + Math.round(left) + "," +
              Math.round(top) + "," + Math.round(right) + "," +
              Math.round(bottom) + "] in " + canvas.width + "x" +
              canvas.height + ": " + JSON.stringify(str.slice(0, 60)));
          }
        } catch (ignore) { /* instrumentation must never break the draw */ }
        return out;
      };
    });
  })();

  // ---- Checks --------------------------------------------------------------

  function squeeze(text) {
    return text.replace(/\s+/g, "");
  }

  // The drawn lines of one band, in draw order, must reconstruct the source
  // string exactly. An ellipsis, a dropped line or a truncated tail all leave
  // the walk short of the end.
  function reconstructs(source) {
    var target = squeeze(source);
    var pos = 0;
    for (var i = 0; i < drawn.length && pos < target.length; i++) {
      var piece = squeeze(drawn[i]);
      if (!piece) continue;
      if (target.startsWith(piece, pos)) pos += piece.length;
    }
    return pos === target.length;
  }

  function checkSize(label) {
    var problems = [];
    SAY.forEach(function (text, slot) {
      if (runes(text).length !== MAX_SAY_LEN) {
        problems.push("say[" + slot + "] is " + runes(text).length +
          " runes, not the full cap " + MAX_SAY_LEN);
      }
    });
    NOTES.forEach(function (text, slot) {
      if (runes(text).length !== MAX_NOTES_LEN) {
        problems.push("notes[" + slot + "] is " + runes(text).length +
          " runes, not the full cap " + MAX_NOTES_LEN);
      }
    });
    if (outside.length) {
      problems.push(outside.length + " draw(s) crossed a canvas edge: " +
        outside.slice(0, 4).join(" | "));
    }
    SAY.forEach(function (text, slot) {
      if (!reconstructs(text)) {
        problems.push("the full-cap say of seat " + slot +
          " was not drawn whole (ellipsized or clipped by the band)");
      }
    });
    NOTES.forEach(function (text, slot) {
      if (!reconstructs(text)) {
        problems.push("the full-cap notes of seat " + slot +
          " were not drawn whole (ellipsized or clipped by the band)");
      }
    });
    return problems.map(function (p) { return label + ": " + p; });
  }

  function checkFeed() {
    var feed = document.getElementById("feed");
    var text = feed ? feed.textContent : "";
    var problems = [];
    SAY.forEach(function (say, slot) {
      if (text.indexOf(say) < 0) {
        problems.push("feed: seat " + slot +
          " remark is missing or truncated in the .feed-say line");
      }
    });
    NOTES.forEach(function (notes, slot) {
      if (text.indexOf(notes) < 0) {
        problems.push("feed: seat " + slot +
          " notes are missing or truncated in the .feed-say line");
      }
    });
    return problems;
  }

  // ---- Run -----------------------------------------------------------------

  function frames(n) {
    return new Promise(function (resolve) {
      (function step(left) {
        if (left <= 0) { resolve(); return; }
        requestAnimationFrame(function () { step(left - 1); });
      })(n);
    });
  }

  function wait(ms) {
    return new Promise(function (resolve) { setTimeout(resolve, ms); });
  }

  function fail(problems) {
    console.error("WORST-CASE FIXTURE FAILED:\n  " + problems.join("\n  "));
    realSetAttribute("data-replay-error", problems[0]);
    var loading = document.getElementById("loading");
    if (loading) loading.textContent = "FIXTURE FAILED: " + problems[0];
  }

  function run() {
    var canvas = document.getElementById("table");
    var problems = [];
    // Sizes are walked worst-first; each one is sampled twice: once a few
    // frames after the resize (the bid slide-in and the verdict tally are
    // mid-animation) and once after the animations have settled.
    return CANVAS_SIZES.reduce(function (chain, size) {
      return chain.then(function () {
        canvas.width = size[0];
        canvas.height = size[1];
        var label = size[0] + "x" + size[1];
        drawn = [];
        outside = [];
        return frames(4).then(function () {
          problems = problems.concat(checkSize(label + " entering"));
          return wait(2900);
        }).then(function () {
          drawn = [];
          outside = [];
          return frames(4);
        }).then(function () {
          problems = problems.concat(checkSize(label + " settled"));
        });
      });
    }, Promise.resolve()).then(function () {
      problems = problems.concat(checkFeed());
      if (!rendererSignalled) {
        problems.push("client/renderer.js never set data-replay-loaded: the " +
          "real renderer path did not run");
      }
      if (problems.length) {
        fail(problems);
        return;
      }
      console.log("worst-case fixture: " + CANVAS_SIZES.length +
        " canvas sizes, " + SAY.length + " full-cap remarks (" + MAX_SAY_LEN +
        " runes) and " + NOTES.length + " full-cap notes (" + MAX_NOTES_LEN +
        " runes) drawn whole, 0 draws outside the canvas");
      realSetAttribute("data-fixture-sizes", String(CANVAS_SIZES.length));
      realSetAttribute("data-replay-loaded", "true");
    });
  }

  function start() {
    var canvas = document.getElementById("table");
    document.getElementById("loading").style.display = "none";
    LiarsDiceRenderer.bindFeedToggle(document.getElementById("feedtoggle"),
      false);
    LiarsDiceRenderer.attachReplay({
      canvas: canvas,
      feed: document.getElementById("feed"),
      scrub: document.getElementById("scrub"),
      playButton: document.getElementById("play"),
      label: document.getElementById("pos"),
      clock: document.getElementById("clock"),
      scorebug: document.getElementById("scorebug"),
      endscreen: document.getElementById("endscreen"),
      assetBase: "./assets",
      payload: PAYLOAD
    });
    LiarsDiceRenderer.relayout();
    run().catch(function (error) {
      fail(["fixture crashed: " + (error && error.stack || error)]);
    });
  }

  // The bands are measured in the face they are drawn in, so the webfont has
  // to be in before the first measurement.
  var fonts = document.fonts && document.fonts.load ?
    document.fonts.load("11px rajdhani").then(function () {
      return document.fonts.ready;
    }) : Promise.resolve();
  fonts.then(start, start);
})();
