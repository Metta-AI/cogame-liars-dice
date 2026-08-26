// Liar's Dice shared renderer + drivers.
//
// One canvas scene (a felt table over the arena floor with the cogs seated
// around it in TABLE order, each with its hand — closed cups during bidding,
// real pipped dice or a serial-number ticket stub once a challenge opens
// them — its alias, its running points and its private-notes parchment; the
// standing-bid plate in the middle of the felt, and a speech plate over
// whoever just talked) fed by three drivers: live /global websocket, live
// /player websocket, and replay (from the game's /replay websocket or the
// static wasm bundle). All state derivation happens server-side / wasm-side;
// this file only draws state objects:
//   {seats:[{slot,seat,name,points,score,wins,losses,hand,revealed,acting,
//            say,notes}],
//    order[], mode, faces, lowFace, handSize, totalSymbols, talk,
//    deal, deals, dealsPlayed, opener, turn,
//    bid:{seat,quantity,face}|null, bids:[…],
//    resolution:{challenger,bidder,quantity,face,actual,counts,bidderWins,
//                forced}|null,
//    phase:"bidding|reveal|between|done", gameDone, reason}
// Seats are indexed by SLOT everywhere; `seat` is the table position, which
// is what the ring placement uses so the seeded seating is visible.
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Liar's
  // Dice seats four cogs: red, blue, green, yellow. The extra colours stay so
  // the chrome's seatN classes keep lining up with the CSS.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CARD_EDGE = "rgba(42, 31, 22, 0.85)";
  // The challenge verdict (banner + counted-up tally) holds for a beat, then
  // fades down to a resting tint so a paused frame still reads.
  var VERDICT_HOLD_MS = 2000;
  var VERDICT_FADE_MS = 700;
  var VERDICT_REST = 0.35;
  var TALLY_MS = 900;
  var BID_SLIDE_MS = 420;

  // Everything drawn on the felt uses the bundled display face; no symbol
  // font is relied on, because the dice are drawn with real pips.
  var BODY_FONT = "'rajdhani', system-ui, sans-serif";

  // Pip layouts for faces 1..6, in unit square coordinates.
  var PIPS = {
    1: [[0.5, 0.5]],
    2: [[0.29, 0.29], [0.71, 0.71]],
    3: [[0.29, 0.29], [0.5, 0.5], [0.71, 0.71]],
    4: [[0.29, 0.29], [0.71, 0.29], [0.29, 0.71], [0.71, 0.71]],
    5: [[0.29, 0.28], [0.71, 0.28], [0.5, 0.5], [0.29, 0.72], [0.71, 0.72]],
    6: [[0.29, 0.26], [0.71, 0.26], [0.29, 0.5], [0.71, 0.5], [0.29, 0.74],
      [0.71, 0.74]]
  };
  var DIE_GLYPHS = ["", "\u2680", "\u2681", "\u2682", "\u2683", "\u2684",
    "\u2685"];

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  // Colour helpers for the die rims / highlights.
  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function shade(hex, factor) {
    var c = hexToRgb(hex).map(function (v) {
      return Math.max(0, Math.min(255, Math.round(v * factor)));
    });
    return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")";
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function signed(value) {
    return value > 0 ? "+" + value : value < 0 ? "−" + Math.abs(value) : "0";
  }

  // Nominal cog size; everything around a cog is measured as a multiple of it
  // so the whole seat block scales as one unit.
  var SEAT_BASE = 84;
  var NOTE_LINES = 3, NOTE_LINE_H = 12, NOTE_PAD = 6;
  var SAY_LINES = 2, SAY_LINE_H = 12, SAY_PAD = 5;

  function noteHeight(scale, lines) {
    return ((lines || NOTE_LINES) * NOTE_LINE_H + NOTE_PAD * 2 - 2) * scale;
  }

  function sayHeight(scale) {
    return (SAY_LINES * SAY_LINE_H + SAY_PAD * 2) * scale;
  }

  // ---- Liar's Dice stage ---------------------------------------------------

  function seatBlock(size, handSize, compact) {
    // The seat block: a reserved speech band, the cog, its hand, the alias
    // and points line, then the notes parchment. The speech band and the
    // parchment are reserved even while a seat is silent and note-less — both
    // arrive without warning, and a plate laid out with no room reserved gets
    // drawn off-frame (cogchemists, 2026-08-24).
    var scale = size / SEAT_BASE;
    var noteLines = compact ? 1 : NOTE_LINES;
    var die = Math.max(11, size * 0.34);
    var handW = handSize * (die + 4 * scale) + 8 * scale;
    return {
      scale: scale,
      die: die,
      handH: die + 8 * scale,
      noteLines: noteLines,
      w: Math.max(size * 1.9, handW),
      above: size * 0.62 + sayHeight(scale),
      below: size * 0.5 + 6 * scale + die + 8 * scale + 34 * scale +
        noteHeight(scale, noteLines)
    };
  }

  function computeLayout(width, height, count, handSize) {
    // Solved per frame: callers embed this viewer at wildly different sizes,
    // and the whole table must always fit the frame (it is a FIXED arena —
    // there is no zoom and no minimap).
    var compact = width < 480;
    var size = Math.min(SEAT_BASE, width / 9, height / 6);
    var layout = null;
    for (var attempt = 0; attempt < 40; attempt++) {
      var block = seatBlock(size, handSize, compact);
      var margin = 6;
      var cy = (height + block.above - block.below) / 2;
      var ry = Math.min(cy - margin - block.above,
        height - margin - block.below - cy);
      var rx = Math.min(width * 0.34, (width - block.w) / 2 - margin);
      var spots = [];
      if (compact) {
        // Below 480px the ring has no room: lay the seats out as a grid and
        // move the standing-bid plate to the top strip.
        var cols = 2;
        var rows = Math.ceil(count / cols);
        var cellH = (height - block.above - block.below) / Math.max(rows, 1);
        for (var g = 0; g < count; g++) {
          var col = g % cols;
          var row = Math.floor(g / cols);
          spots.push({
            x: width * (col === 0 ? 0.25 : 0.75),
            y: block.above + cellH * row + cellH / 2
          });
        }
      } else {
        for (var i = 0; i < count; i++) {
          var a = -Math.PI / 2 + i * Math.PI * 2 / count;
          spots.push({ x: width / 2 + Math.cos(a) * rx,
            y: cy + Math.sin(a) * ry });
        }
      }
      // Clamp every block wholly inside the frame; nothing is ever drawn
      // outside the canvas.
      spots = spots.map(function (spot) {
        return {
          x: Math.max(block.w / 2 + margin,
            Math.min(width - block.w / 2 - margin, spot.x)),
          y: Math.max(block.above + margin,
            Math.min(height - block.below - margin, spot.y))
        };
      });
      var plate = compact ?
        { x: width / 2, y: Math.max(28, block.above * 0.55) } :
        { x: width / 2, y: cy };
      layout = { size: size, scale: block.scale, block: block, spots: spots,
        plate: plate, compact: compact, width: width, height: height };
      if ((ry >= size * 0.5 && rx >= size && !compact) ||
          (compact && block.above + block.below < height) || size < 22) {
        break;
      }
      size *= 0.92;
    }
    return layout;
  }

  function actingSlot(view) {
    var seats = view.seats || [];
    for (var i = 0; i < seats.length; i++) {
      if (seats[i] && seats[i].acting) return i;
    }
    return -1;
  }

  function faceLabel(face, mode) {
    if (mode === "poker") return String(face);
    return DIE_GLYPHS[face] || String(face);
  }

  function bidLabel(quantity, face, mode) {
    return quantity + " × " + faceLabel(face, mode);
  }

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var now = view.now || Date.now();
    var handSize = view.handSize || (seats[0] && seats[0].hand &&
      seats[0].hand.length) || 5;
    var layout = computeLayout(w, h, Math.max(seats.length, 1), handSize);
    var fx = view.effects || {};
    var order = view.order && view.order.length ? view.order :
      seats.map(function (_, i) { return i; });

    // Floor, then the felt oval the table is played on.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.5)";
    ctx.fillRect(0, 0, w, h);
    drawFelt(ctx, w, h, layout);

    var acting = actingSlot(view);
    var res = view.resolution || null;
    var challengeAge = typeof fx.challengeAt === "number" ?
      now - fx.challengeAt : null;

    // Seats, in TABLE order: ring position p holds slot order[p].
    for (var p = 0; p < order.length; p++) {
      var slot = order[p];
      var seat = seats[slot];
      var spot = layout.spots[p];
      if (!seat || !spot) continue;
      drawSeat(ctx, images, seat, slot, spot, layout, view, {
        acting: acting === slot && !view.done,
        highlightFace: res ? res.face : -1,
        challengeAge: challengeAge
      });
    }

    // The standing-bid plate in the middle of the felt.
    drawBidPlate(ctx, layout, view, fx, now);

    if (res) {
      drawVerdict(ctx, layout, view, res, challengeAge);
    }
  }

  function drawFelt(ctx, w, h, layout) {
    var cx = w / 2;
    var cy = layout.compact ? h * 0.5 : layout.plate.y;
    var rx = Math.min(w * 0.42, w / 2 - 8);
    var ry = Math.min(h * 0.40, h / 2 - 8);
    ctx.save();
    ctx.translate(cx, cy);
    ctx.scale(1, ry / rx);
    var grad = ctx.createRadialGradient(0, 0, rx * 0.1, 0, 0, rx);
    grad.addColorStop(0, "rgba(41, 84, 58, 0.92)");
    grad.addColorStop(0.72, "rgba(26, 58, 39, 0.88)");
    grad.addColorStop(1, "rgba(16, 34, 23, 0.6)");
    ctx.beginPath();
    ctx.arc(0, 0, rx, 0, Math.PI * 2);
    ctx.fillStyle = grad;
    ctx.fill();
    ctx.strokeStyle = "rgba(232, 163, 61, 0.28)";
    ctx.lineWidth = 3;
    ctx.stroke();
    ctx.restore();
  }

  // Cog, acting ring, speech plate, hand, alias + points, notes parchment.
  function drawSeat(ctx, images, seat, slot, spot, layout, view, opts) {
    var size = layout.size;
    var scale = layout.scale;
    var block = layout.block;
    var color = seatColor(slot);
    var hex = COLOR_HEX[color];
    var sprite = images["soldier_" + color + "_front.png"];

    // Speech plate: drawn DOWNWARD from its own top edge and clamped inside
    // the canvas, so a seat at the top of the frame never pushes its talk
    // off-screen.
    if (view.talk !== false && seat.say) {
      drawSpeech(ctx, spot.x, spot.y - size * 0.62 - sayHeight(scale),
        block.w, seat.say, scale, hex, layout);
    }

    ctx.save();
    ctx.translate(spot.x, spot.y);
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
    } else {
      ctx.fillStyle = hex;
      ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
    }
    ctx.restore();

    if (opts.acting) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 3;
      ctx.setLineDash([6, 5]);
      ctx.beginPath();
      ctx.arc(spot.x, spot.y, size * 0.62, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
      drawTag(ctx, spot.x, spot.y - size * 0.52, "▶ TO ACT", AMBER, scale);
    }

    // The hand, in front of the cog.
    var handTop = spot.y + size * 0.5 + 6 * scale;
    drawHand(ctx, spot.x, handTop, block, seat, view, hex, opts);

    // Alias and points.
    var textY = handTop + block.handH + 13 * scale;
    ctx.save();
    ctx.font = "600 " + Math.max(10, Math.round(13 * scale)) + "px " +
      BODY_FONT;
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    ctx.fillStyle = opts.acting ? PAPER : "rgba(242, 232, 216, 0.82)";
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    ctx.fillText(ellipsize(ctx, seat.name || "", block.w - 4), spot.x, textY);
    ctx.font = "700 " + Math.max(10, Math.round(14 * scale)) + "px " +
      BODY_FONT;
    ctx.fillStyle = (seat.points || 0) >= 0 ? AMBER : COLOR_HEX.red;
    ctx.fillText(signed(seat.points || 0), spot.x, textY + 15 * scale);
    ctx.restore();

    // Notes parchment: the read on the table forming in public.
    drawParchment(ctx, spot.x - block.w / 2, textY + 21 * scale, block.w,
      seat.notes || "", scale, block.noteLines);
  }

  function drawHand(ctx, cx, top, block, seat, view, hex, opts) {
    var hand = seat.hand || [];
    var count = hand.length || view.handSize || 0;
    if (!count) return;
    var die = block.die;
    var gap = 4 * block.scale;
    var totalW = count * die + (count - 1) * gap;
    var x = cx - totalW / 2;
    var poker = view.mode === "poker";
    for (var i = 0; i < count; i++) {
      var face = hand[i];
      var lit = seat.revealed && opts.highlightFace >= 0 &&
        face === opts.highlightFace;
      if (!seat.revealed) {
        drawCup(ctx, x + i * (die + gap), top, die, hex);
      } else if (poker) {
        drawTicketCell(ctx, x + i * (die + gap), top, die, face, hex, lit,
          opts.challengeAge);
      } else {
        drawDie(ctx, x + i * (die + gap), top, die, face, hex, lit,
          opts.challengeAge);
      }
    }
  }

  function drawCup(ctx, x, y, s, hex) {
    ctx.save();
    ctx.beginPath();
    ctx.moveTo(x + s * 0.14, y + s * 0.06);
    ctx.lineTo(x + s * 0.86, y + s * 0.06);
    ctx.lineTo(x + s, y + s);
    ctx.lineTo(x, y + s);
    ctx.closePath();
    ctx.fillStyle = "rgba(28, 21, 15, 0.94)";
    ctx.fill();
    ctx.strokeStyle = rgba(hex, 0.85);
    ctx.lineWidth = 1.5;
    ctx.stroke();
    ctx.fillStyle = rgba(hex, 0.75);
    ctx.fillRect(x + s * 0.1, y + s * 0.22, s * 0.8, s * 0.14);
    ctx.restore();
  }

  function pulse(age) {
    if (age === null || age === undefined) return VERDICT_REST;
    if (age < VERDICT_HOLD_MS) {
      return 0.75 + 0.25 * Math.sin(age / 90);
    }
    return Math.max(VERDICT_REST,
      1 - (age - VERDICT_HOLD_MS) / VERDICT_FADE_MS * (1 - VERDICT_REST));
  }

  function drawDie(ctx, x, y, s, face, hex, lit, age) {
    ctx.save();
    ctx.shadowColor = "rgba(0,0,0,0.5)";
    ctx.shadowBlur = 4;
    ctx.fillStyle = PAPER;
    roundRect(ctx, x, y, s, s, s * 0.2);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.strokeStyle = lit ? rgba(AMBER, pulse(age)) : rgba(hex, 0.85);
    ctx.lineWidth = lit ? 2.5 : 1.5;
    ctx.stroke();
    if (lit) {
      ctx.fillStyle = rgba(AMBER, 0.28 * pulse(age));
      roundRect(ctx, x, y, s, s, s * 0.2);
      ctx.fill();
    }
    var spots = PIPS[face] || [];
    ctx.fillStyle = INK;
    for (var i = 0; i < spots.length; i++) {
      ctx.beginPath();
      ctx.arc(x + spots[i][0] * s, y + spots[i][1] * s, s * 0.085, 0,
        Math.PI * 2);
      ctx.fill();
    }
    // Numeral badge: a spectator reads "5", not a pip count to total.
    if (s >= 17) {
      ctx.font = "700 " + Math.max(8, Math.round(s * 0.3)) + "px " + BODY_FONT;
      ctx.textAlign = "right";
      ctx.textBaseline = "alphabetic";
      ctx.fillStyle = shade(hex, 0.85);
      ctx.fillText(String(face), x + s - s * 0.1, y + s - s * 0.1);
    }
    ctx.restore();
  }

  function drawTicketCell(ctx, x, y, s, digit, hex, lit, age) {
    ctx.save();
    ctx.fillStyle = PAPER;
    ctx.strokeStyle = lit ? rgba(AMBER, pulse(age)) : rgba(hex, 0.8);
    ctx.lineWidth = lit ? 2.5 : 1.2;
    roundRect(ctx, x, y, s, s, s * 0.12);
    ctx.fill();
    ctx.stroke();
    if (lit) {
      ctx.fillStyle = rgba(AMBER, 0.28 * pulse(age));
      roundRect(ctx, x, y, s, s, s * 0.12);
      ctx.fill();
    }
    // Perforation down the right edge, so the row reads as a ticket stub.
    ctx.strokeStyle = "rgba(42, 31, 22, 0.35)";
    ctx.lineWidth = 1;
    ctx.setLineDash([2, 3]);
    ctx.beginPath();
    ctx.moveTo(x + s, y + s * 0.12);
    ctx.lineTo(x + s, y + s * 0.88);
    ctx.stroke();
    ctx.setLineDash([]);
    // Digits are drawn as DIGITS, never as letters.
    ctx.font = "700 " + Math.max(9, Math.round(s * 0.62)) + "px " + BODY_FONT;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillStyle = INK;
    ctx.fillText(String(digit), x + s / 2, y + s * 0.54);
    ctx.restore();
  }

  function drawSpeech(ctx, cx, top, width, text, scale, hex, layout) {
    var pad = SAY_PAD * scale;
    var lineH = SAY_LINE_H * scale;
    var h = sayHeight(scale);
    var w = width;
    var x = Math.max(4, Math.min(layout.width - w - 4, cx - w / 2));
    var y = Math.max(4, Math.min(layout.height - h - 4, top));
    ctx.save();
    ctx.font = Math.max(9, Math.round(10.5 * scale)) + "px " + BODY_FONT;
    var lines = wrapLines(ctx, text, w - pad * 2, SAY_LINES);
    ctx.fillStyle = "rgba(242, 232, 216, 0.94)";
    ctx.strokeStyle = rgba(hex, 0.9);
    ctx.lineWidth = 1.5;
    roundRect(ctx, x, y, w, h, 5 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    lines.forEach(function (line, i) {
      ctx.fillText(line, x + pad, y + pad + i * lineH);
    });
    ctx.restore();
  }

  function drawParchment(ctx, x, y, w, text, scale, lines) {
    var count = lines || NOTE_LINES;
    var pad = NOTE_PAD * scale;
    var lineH = NOTE_LINE_H * scale;
    var h = noteHeight(scale, count);
    ctx.save();
    ctx.font = Math.max(9, Math.round(10.5 * scale)) + "px " + BODY_FONT;
    var rows = text ? wrapLines(ctx, text, w - pad * 2, count) : [];
    ctx.fillStyle = text ? "rgba(242, 232, 216, 0.92)" :
      "rgba(242, 232, 216, 0.10)";
    ctx.strokeStyle = text ? CARD_EDGE : "rgba(242, 232, 216, 0.18)";
    ctx.lineWidth = 1;
    ctx.setLineDash(text ? [] : [3, 3]);
    roundRect(ctx, x, y, w, h, 3 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.setLineDash([]);
    // Folded corner.
    if (text) {
      ctx.beginPath();
      ctx.moveTo(x + w - 7 * scale, y);
      ctx.lineTo(x + w, y + 7 * scale);
      ctx.lineTo(x + w - 7 * scale, y + 7 * scale);
      ctx.closePath();
      ctx.fillStyle = "rgba(42, 31, 22, 0.25)";
      ctx.fill();
    }
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    if (text) {
      ctx.fillStyle = INK;
      rows.forEach(function (line, i) {
        ctx.fillText(line, x + pad, y + pad + i * lineH);
      });
    } else {
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.max(8, Math.round(8 * scale)) + "px " +
        BODY_FONT;
      ctx.fillText("NO NOTES YET", x + pad, y + pad);
    }
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  // The standing bid, big, in the bidder's colour, sliding in as it lands.
  function drawBidPlate(ctx, layout, view, fx, now) {
    var bid = view.bid;
    var seats = view.seats || [];
    var scale = Math.max(0.7, layout.scale);
    var w = Math.min(layout.width - 24, 230 * scale);
    var h = 86 * scale;
    var cx = layout.plate.x;
    var cy = layout.plate.y;
    var slide = typeof fx.bidAt === "number" ?
      Math.min(1, (now - fx.bidAt) / BID_SLIDE_MS) : 1;
    var eased = 1 - Math.pow(1 - slide, 3);
    var y = Math.max(4, Math.min(layout.height - h - 4, cy - h / 2));
    var x = Math.max(4, Math.min(layout.width - w - 4, cx - w / 2));
    ctx.save();
    ctx.globalAlpha = 0.55 + 0.45 * eased;
    ctx.fillStyle = "rgba(18, 13, 9, 0.78)";
    ctx.strokeStyle = bid ?
      rgba(COLOR_HEX[seatColor(bid.seat)], 0.95) :
      "rgba(242, 232, 216, 0.2)";
    ctx.lineWidth = 2;
    roundRect(ctx, x, y, w, h, 8 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    if (!bid) {
      ctx.font = "600 " + Math.max(10, Math.round(13 * scale)) + "px " +
        BODY_FONT;
      ctx.fillStyle = GHOST;
      ctx.fillText(view.phase === "bidding" ? "NO BID YET" : "TABLE IDLE",
        x + w / 2, y + h / 2);
      ctx.restore();
      return;
    }
    var hex = COLOR_HEX[seatColor(bid.seat)];
    var big = Math.max(18, Math.round(34 * scale));
    var dieSize = big * 0.95;
    ctx.font = "700 " + big + "px " + BODY_FONT;
    var head = bid.quantity + " ×";
    var headW = ctx.measureText(head).width;
    var groupW = headW + 8 * scale + dieSize;
    var left = x + (w - groupW) / 2;
    var midY = y + h * 0.42;
    ctx.fillStyle = hex;
    ctx.textAlign = "left";
    ctx.fillText(head, left, midY);
    if (view.mode === "poker") {
      drawTicketCell(ctx, left + headW + 8 * scale, midY - dieSize / 2,
        dieSize, bid.face, hex, false, null);
    } else {
      drawDie(ctx, left + headW + 8 * scale, midY - dieSize / 2, dieSize,
        bid.face, hex, false, null);
    }
    ctx.font = "600 " + Math.max(9, Math.round(11 * scale)) + "px " +
      BODY_FONT;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillStyle = "rgba(242, 232, 216, 0.86)";
    var who = (seats[bid.seat] && seats[bid.seat].name) || "";
    ctx.fillText(ellipsize(ctx, "bid by " + who, w - 16), x + w / 2,
      y + h * 0.82);
    ctx.restore();
  }

  // Running tally over the plate, then the verdict banner.
  function drawVerdict(ctx, layout, view, res, age) {
    var scale = Math.max(0.7, layout.scale);
    var alpha = age === null || age === undefined ? VERDICT_REST :
      age < VERDICT_HOLD_MS ? 1 :
      Math.max(VERDICT_REST,
        1 - (age - VERDICT_HOLD_MS) / VERDICT_FADE_MS * (1 - VERDICT_REST));
    var shown = age === null || age === undefined ? res.actual :
      Math.min(res.actual, Math.ceil(res.actual * Math.min(1, age / TALLY_MS)));
    var seats = view.seats || [];
    var winner = res.bidderWins ? res.bidder : res.challenger;
    var hex = COLOR_HEX[seatColor(winner)];
    var w = Math.min(layout.width - 24, 260 * scale);
    var h = 46 * scale;
    var x = Math.max(4, Math.min(layout.width - w - 4,
      layout.plate.x - w / 2));
    var y = Math.max(4, Math.min(layout.height - h - 4,
      layout.plate.y + (layout.compact ? 56 : 60) * scale));
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.fillStyle = "rgba(18, 13, 9, 0.88)";
    ctx.strokeStyle = rgba(hex, 0.95);
    ctx.lineWidth = 2;
    roundRect(ctx, x, y, w, h, 6 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "700 " + Math.max(11, Math.round(15 * scale)) + "px " +
      BODY_FONT;
    ctx.fillStyle = res.bidderWins ? hex : AMBER;
    ctx.fillText(res.bidderWins ? "THE BID HELD" : "BLUFF CALLED",
      x + w / 2, y + h * 0.34);
    ctx.font = "600 " + Math.max(9, Math.round(12 * scale)) + "px " +
      BODY_FONT;
    ctx.fillStyle = "rgba(242, 232, 216, 0.9)";
    var line = shown + " / " + res.quantity + " · " +
      ((seats[res.challenger] && seats[res.challenger].name) || "") +
      (res.forced ? " (forced)" : "") + " called " +
      ((seats[res.bidder] && seats[res.bidder].name) || "");
    ctx.fillText(ellipsize(ctx, line, w - 14), x + w / 2, y + h * 0.74);
    ctx.restore();
  }

  // A small tag ("▶ TO ACT") in the seat's colour, pinned over the cog.
  function drawTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.max(8, Math.round(10 * scale)) + "px " +
      BODY_FONT;
    var label = text.toUpperCase();
    var pad = 5 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale);
    ctx.restore();
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the underlying
  // events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  // Deal numbers in events are 0-based per the sim; a payload that counts
  // from 1 is tolerated by reading the first deal event.
  function dealBase(events) {
    for (var i = 0; i < events.length; i++) {
      if (events[i].kind === "deal") return events[i].deal === 1 ? 1 : 0;
    }
    return 0;
  }

  // `ctx` carries what a line needs from earlier events: the running points
  // and the game's mode.
  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "Table set — hidden hands, one claim at a time.";
      case "deal":
        return "Fresh hands dealt — " + name(event.opener) + " opens.";
      case "bid":
        return name(event.seat) + " bids " +
          bidLabel(event.quantity, event.face, ctx.mode) +
          (event.fallback ? " (fallback)" : "");
      case "challenge":
        return name(event.seat) +
          (event.forced ? " is forced to call LIAR" : " calls LIAR") +
          " — actual " + event.actual +
          (event.bidderWins ? " ≥ " : " < ") + event.quantity + " — " +
          (event.bidderWins ?
            name(event.other) + " +1, " + name(event.seat) + " −1" :
            name(event.seat) + " +1, " + name(event.other) + " −1");
      case "end":
        return endText(event, ctx);
      default: return JSON.stringify(event);
    }
  }

  function endText(event, ctx) {
    var points = ctx.points || [];
    var best = -1;
    var bestPoints = -Infinity;
    for (var i = 0; i < points.length; i++) {
      if (points[i] > bestPoints) { bestPoints = points[i]; best = i; }
    }
    var level = points.every(function (v) { return v === bestPoints; });
    var deals = ctx.deals || 0;
    var score = deals ? 0.5 + bestPoints / (2 * deals) : 0.5;
    var head = (level || best < 0) ? "Final — all level" :
      "Final — " + clampName(ctx.nameMap.seat(best)) + " " +
        signed(bestPoints) + " (" + score.toFixed(2) + ")";
    return head + (event.text === "deadline" ? " — episode deadline." : ".");
  }

  function blockHead(block) {
    return block < 0 ? "SETUP" : "DEAL " + (block + 1);
  }

  // Renders the full transcript grouped into one section per deal.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex, mode) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var base = dealBase(events);
    var html = "";
    var lastBlock = null;
    var seatCount = 0;
    events.forEach(function (event) {
      if (event.kind === "deal" && event.hands) {
        seatCount = Math.max(seatCount, event.hands.length);
      }
      if (event.kind === "challenge" && event.counts) {
        seatCount = Math.max(seatCount, event.counts.length);
      }
    });
    var ctx = {
      points: new Array(seatCount).fill(0),
      deals: 0,
      mode: mode || "dice",
      nameMap: nameMap
    };
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.deal - base;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) + "</div>";
        lastBlock = block;
      }
      if (event.kind === "challenge") {
        ctx.deals += 1;
        var winner = event.bidderWins ? event.other : event.seat;
        var loser = event.bidderWins ? event.seat : event.other;
        if (ctx.points[winner] !== undefined) ctx.points[winner] += 1;
        if (ctx.points[loser] !== undefined) ctx.points[loser] -= 1;
      }
      var scored = event.kind === "challenge";
      var winnerSeat = scored ?
        (event.bidderWins ? event.other : event.seat) : event.seat;
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "bid" ? " seat" + (event.seat % COLORS.length) : "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (event.forced ? " feed-forced" : "") +
        (scored ? " feed-score seat" + (winnerSeat % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, nameMap, ctx)) + "</div>";
      // Table talk, in the speaker's own line.
      if (event.say) {
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + ': "' +
            nameMap.text(event.say) + '"') + "</div>";
      }
      // Notes: only when the seat's notes changed.
      if ((event.kind === "bid" || event.kind === "challenge") &&
          event.notes && event.notes !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.notes;
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.notes)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when the standing bid landed (the plate slides in) and when the challenge
  // landed (the tally counts up and the verdict fades from it).
  function makeEffects() {
    var seen = 0;
    var bidAt = null;
    var challengeAt = null;
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest events get to animate — replaying every historical verdict as
      // a fresh flash would strobe the table.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "deal") {
            bidAt = null;
            challengeAt = null;
          } else if (event.kind === "bid") {
            bidAt = animate ? now : null;
          } else if (event.kind === "challenge") {
            challengeAt = animate ? now : null;
          }
        }
      },
      reset: function () { seen = 0; bidAt = null; challengeAt = null; },
      view: function () {
        return { effects: { bidAt: bidAt, challengeAt: challengeAt } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function phaseText(state, nameMap) {
    if (state.gameDone || state.done) return "FINAL";
    var seats = state.seats || [];
    for (var i = 0; i < seats.length; i++) {
      if (seats[i] && seats[i].acting) {
        var who = nameMap ? nameMap.seat(i) : seats[i].name;
        return clampName(who).toUpperCase() + " TO ACT";
      }
    }
    var res = state.resolution;
    if (res) {
      var caller = nameMap ? nameMap.seat(res.challenger) :
        (seats[res.challenger] || {}).name || "";
      return clampName(caller).toUpperCase() + " CHALLENGES";
    }
    return "";
  }

  function matchHeader(state, config, nameMap) {
    var parts = [];
    if (state) {
      var played = state.dealsPlayed || 0;
      var live = state.phase === "bidding";
      var total = state.deals || (config && config.deals) || 0;
      var shown = played + (live ? 1 : 0);
      if (total) shown = Math.min(shown, total);
      parts.push("DEAL " + shown + (total ? " / " + total : ""));
      var phase = phaseText(state, nameMap);
      if (phase) parts.push(phase);
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var pips = "";
      for (var p = 0; p < Math.min(seat.wins || 0, 12); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      for (var q = 0; q < Math.min(seat.losses || 0, 12); q++) {
        pips += '<span class="plate-pip hollow"></span>';
      }
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.acting && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + signed(seat.points || 0) + "</span>" +
        '<span class="plate-label">points</span>' +
        '<span class="plate-pips">' + pips + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.deals || 0) +
          " of " + (results.maxDeals || results.deals || 0) + " deals";
      default: return "";
    }
  }

  function ratio(value, total) {
    if (!total) return "0%";
    return Math.round(value / total * 100) + "%";
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var points = results.points || [];
    var wins = results.wins || [];
    var losses = results.losses || [];
    var bids = results.bids || [];
    var challenges = results.challenges || [];
    var bluff = results.bluffRate || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      var byScore = (scores[b] || 0) - (scores[a] || 0);
      if (byScore) return byScore;
      return (points[b] || 0) - (points[a] || 0);
    });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " TAKES THE TABLE" : "ALL LEVEL";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.deals || 0) + " DEAL" +
      ((results.deals || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">score</span>' +
      '<span class="end-head">W</span>' +
      '<span class="end-head">L</span>' +
      '<span class="end-head">bluff rate</span>' +
      '<span class="end-head">challenge rate</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell((scores[i] || 0).toFixed(2)) +
        cell(wins[i] || 0) +
        cell(losses[i] || 0) +
        cell(Math.round((bluff[i] || 0) * 100) + "%") +
        cell(ratio(challenges[i] || 0,
          (challenges[i] || 0) + (bids[i] || 0)));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  // relayout(): measures the transport band and publishes --band and
  // --hudscale on :root (never on #stage, where a :root-scoped consumer would
  // never see them). The endcard lives inside #board-wrap, the transport's
  // sibling, so its floor is exactly the band's top edge.
  function relayout() {
    var root = document.documentElement;
    if (!root) return;
    var transport = document.getElementById("transport");
    var band = transport ?
      Math.round(transport.getBoundingClientRect().height) : 0;
    root.style.setProperty("--band", band + "px");
    var stage = document.getElementById("stage");
    var width = (stage && stage.clientWidth) || window.innerWidth || 960;
    var scale = Math.max(0.7, Math.min(1.4, width / 960));
    root.style.setProperty("--hudscale", scale.toFixed(3));
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
        relayout();
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
      relayout();
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.order = state.order || [];
    view.mode = state.mode || "dice";
    view.faces = state.faces || 6;
    view.lowFace = typeof state.lowFace === "number" ? state.lowFace : 1;
    view.handSize = state.handSize || 0;
    view.totalSymbols = state.totalSymbols || 0;
    view.talk = state.talk !== false;
    view.deal = typeof state.deal === "number" ? state.deal : -1;
    view.deals = state.deals || 0;
    view.dealsPlayed = state.dealsPlayed || 0;
    view.bid = state.bid || null;
    view.resolution = state.resolution || null;
    view.phase = state.phase || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen, assetBase,
    //           wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var slot = -1;
      // Player pages get no policyNames (they must not learn who is behind a
      // seat) and a redacted state (no hands, no bids), so their map degrades
      // to the table aliases and an empty table.
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = data;
            if (latest) {
              if (typeof latest.slot === "number") slot = latest.slot;
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined, latest.mode);
              }
              if (options.clock) {
                options.clock.textContent =
                  matchHeader(latest, latest, nameMap);
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          if (slot >= 0 && view.seats[slot]) view.seats[slot].own = true;
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per deal, and one
  // LABELLED, CLICKABLE button per beat — a thin tick per bid in the bidder's
  // colour, a fat glowing mark when a bluff was caught, a hollow one when the
  // bid held (dashed when the bid cap forced the call), and the end.
  function buildScrub(container, events, onSeek, nameMap, mode) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var base = dealBase(events);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.deal - base;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    function who(index) {
      return clampName(nameMap ? nameMap.seat(index) : "Seat " + index);
    }
    events.forEach(function (event, i) {
      var kind = event.kind;
      if (kind !== "bid" && kind !== "challenge" && kind !== "end") return;
      var classes = "beat-marker";
      var label = "";
      if (kind === "bid") {
        classes += " bid seat" + (event.seat % COLORS.length);
        label = "Deal " + (event.deal + 1) + " · " + who(event.seat) +
          " bids " + bidLabel(event.quantity, event.face, mode);
      } else if (kind === "challenge") {
        classes += event.bidderWins ?
          " challenge-miss seat" + (event.other % COLORS.length) :
          " challenge-hit seat" + (event.seat % COLORS.length);
        if (event.forced) classes += " forced";
        label = "Deal " + (event.deal + 1) + " · " + who(event.seat) +
          (event.forced ? " forced to challenge " : " challenges ") +
          who(event.other) + " — actual " + event.actual +
          (event.bidderWins ? " ≥ " : " < ") + event.quantity;
      } else {
        classes += " end";
        label = "Final — " + (event.deal || 0) + " deals";
      }
      var marker = document.createElement("button");
      marker.type = "button";
      marker.className = classes;
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      marker.setAttribute("aria-label", label);
      marker.title = label;
      // Seeks through the SAME onSeek the track uses, so the endcard is
      // dismissed exactly as a drag would dismiss it.
      marker.onclick = function (evt) {
        evt.stopPropagation();
        onSeek(i + 1);
      };
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var mode = config.mode || "dice";
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      }, nameMap, mode);
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", dealsPlayed: 0, deals: config.deals || 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) {
          renderFeed(options.feed, events, nameMap, index, mode);
        }
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent =
            matchHeader(currentState(), config, nameMap);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        // Every seek re-runs this with show = index >= events.length, so any
        // seek to an earlier index takes the endcard down.
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at — the event just
        // absorbed — so the bid gets read and the verdict gets seen before
        // the next beat.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "bid" ? 1300 :
          shown && shown.kind === "challenge" ? 2600 :
          shown && shown.kind === "deal" ? 900 :
          shown && shown.kind === "end" ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.LiarsDiceRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle,
    relayout: relayout
  };
})();
